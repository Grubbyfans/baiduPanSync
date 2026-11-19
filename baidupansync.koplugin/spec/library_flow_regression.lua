-- Exercise entry-point lifecycle: display cached data before the network,
-- preserve it on failure, and never resurrect a closed library on completion.
package.path='baidupansync.koplugin/?.lua;'..package.path
local queue,errors,shown,saved,invalidated={},0,0,0,0
local UI={scheduleIn=function(_,_,cb)queue[#queue+1]=cb end,close=function(_,w)
    w.closed=true;if w.on_close then w.on_close(w)end
end}
package.loaded['ui/uimanager']=UI
package.loaded['ui/widget/container/widgetcontainer']={extend=function(_,o)return o end}
package.loaded.datastorage={};package.loaded.device={model='fixture'}
package.loaded['ui/event']={};package.loaded['ffi/util']={};package.loaded.gettext=function(s)return s end
for _,name in ipairs({'book_identity','config_store','storage','progress','sync_state'})do package.loaded['modules/'..name]={}end
package.loaded['ui/menu']={};package.loaded.logger={info=function()end,warn=function()end}
package.loaded['modules/book_cover']={extract=function()end}
package.loaded['modules/local_library']={}
package.loaded['ui/task_progress']={new=function()return {
    state=function()end,phase=function()end,close=function()end,is_cancelled=function()return false end,
    hash_start=function()end,report=function()end,set_stage=function()end,
}end}
local notice
package.loaded['ui/progress_dialog']={error=function(e)errors=errors+1;notice=e end,
    info=function(text,persistent)notice={text=text,persistent=persistent}end,
    result=function(title,text,actions)notice={text=text,persistent=true,actions=actions}end}
G_reader_settings={readSetting=function()return '/books' end}
local cached={backend='fixture',backend_id='backend',entries={},issues={},unpublished={}}
local cache={load=function()return cached end,save=function()saved=saved+1;return true end,
    invalidate=function()invalidated=invalidated+1 end}
package.loaded['modules/library_cache']={new=function()return cache end}
local pending,list_calls= nil,0
package.loaded['modules/cloud_service']={new=function()
    return {list=function(_,opts,done)list_calls=list_calls+1;pending=done;assert(opts.cached_result==cached)end,
        repair_book=function(_,entry,opts,done)
            assert(entry.book_id=='id');done(nil,{record={bookId='id',title='repaired'},entry={record={bookId='id'}}})
        end}
end}
package.loaded['ui/cloud_dialog']={library=function(result,download,page,on_show,on_close,state,on_delete,on_repair,on_refresh)
    shown=shown+1
    local grid={result=result,page=2,on_close=on_close,on_repair=on_repair,on_refresh=on_refresh,
        updateResult=function(self,r)self.result=r end}
    on_show(grid);return grid
end}
local Plugin=dofile('baidupansync.koplugin/main.lua')
local plugin=setmetatable({active_backend='webdav',dav_adapter={backend_id='backend',root='fixture'},settings_dir='/fixture',
    refreshHome=function()end,_hash_opts=function()return {is_cancelled=function()return false end}end,
    progress={capture=function()error('library/repair must not require a local document')end}}, {__index=Plugin})
plugin:onCloudLibrary()
local first=plugin.library_dialog
assert(first.result==cached and cached.refreshing and list_calls==0 and plugin.dav_busy)
table.remove(queue,1)();assert(list_calls==1)
pending({code='NETWORK',message='offline'})
assert(not plugin.dav_busy and plugin.library_dialog==first and first.result.cached~=false and cached.refresh_error=='offline')
local fresh={backend='fixture',backend_id='backend',entries={},issues={},unpublished={}}
plugin:onCloudLibrary();local second=plugin.library_dialog
table.remove(queue,1)();pending(nil,fresh)
assert(second==plugin.library_dialog and second.result==fresh and second.page==2 and saved==1)
plugin:onCloudLibrary();local closing=plugin.library_dialog
UI:close(closing);local before=shown;table.remove(queue,1)()
assert(shown==before and not plugin.dav_busy,'closing cached view before refresh must cancel without reopening')
plugin:onCloudLibrary();closing=plugin.library_dialog
table.remove(queue,1)();UI:close(closing);before=shown;pending(nil,fresh)
assert(shown==before and plugin.library_dialog==nil and saved==2)
-- A successful repair updates the visible orphan list without a local EPUB.
cached={backend='fixture',backend_id='backend',entries={},issues={},unpublished={{book_id='id'}}}
plugin:onCloudLibrary();table.remove(queue,1)();pending(nil,cached)
plugin.library_dialog.on_repair(cached.unpublished[1])
assert(#plugin.library_dialog.result.unpublished==0 and #plugin.library_dialog.result.entries==1)
assert(invalidated==1 and notice.persistent and not plugin.dav_busy)
print('Cached library first paint, offline retention, closed-view safety and repair UI lifecycle regressions passed')
