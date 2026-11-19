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
package.loaded['modules/local_library']={root=function()return '/books'end}
package.loaded['modules/publication_recovery']={new=function()return {list=function()return {}end}end}
package.loaded['modules/local_books']={new=function()return {load=function()return nil end}end}
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
local today=true
local cache={load=function()return cached end,fresh=function()return today end,
    save=function(_,_,value)saved=saved+1;cached=value;return true end,
    invalidate=function()invalidated=invalidated+1 end}
package.loaded['modules/library_cache']={new=function()return cache end}
local pending,list_calls=nil,0
local forced=false
package.loaded['modules/cloud_service']={new=function()
    return {list=function(_,opts,done)list_calls=list_calls+1;pending=done;assert(opts.reconcile_books==forced)end}
end}
package.loaded['ui/cloud_dialog']={library=function(result,download,page,on_show,on_close,state,on_delete,on_repair,on_refresh)
    shown=shown+1
    local grid={result=result,page=2,on_close=on_close,on_repair=on_repair,on_refresh=on_refresh,
        updateResult=function(self,r)self.result=r end,rebuild=function()end}
    on_show(grid);return grid
end}
local Plugin=dofile('baidupansync.koplugin/main.lua')
Plugin._saveDiagnostic=function()end
local plugin=setmetatable({active_backend='webdav',dav_adapter={backend_id='backend',root='fixture'},settings_dir='/fixture',
    refreshHome=function()end,_hash_opts=function()return {is_cancelled=function()return false end}end,
    progress={capture=function()error('library/repair must not require a local document')end}}, {__index=Plugin})
-- Same-day visits are purely local, and the manual button forces a download.
plugin:onCloudLibrary()
local first=plugin.library_dialog
assert(first.result==cached and list_calls==0 and not plugin.dav_busy)
plugin:onCloudLibrary();assert(list_calls==0 and plugin.library_dialog==first)
forced=true;first.on_refresh();assert(plugin.dav_busy and #queue==1)
table.remove(queue,1)();assert(list_calls==1)
local fresh={backend='fixture',backend_id='backend',entries={},issues={},unpublished={}}
pending(nil,fresh);forced=false
assert(not plugin.dav_busy and first.result==fresh and saved==1)
plugin:onCloudLibrary();assert(list_calls==1)
-- Next-day first visit refreshes; failure keeps cached data and permits retry.
today=false
plugin:onCloudLibrary();table.remove(queue,1)();assert(list_calls==2)
pending({code='NETWORK',message='offline'})
assert(not plugin.dav_busy and first.result.refresh_error=='offline')
plugin:onCloudLibrary();table.remove(queue,1)();assert(list_calls==3)
pending(nil,fresh);assert(saved==2)
-- Closing a cached view before refresh cancels without resurrecting it.
plugin:onCloudLibrary();local closing=plugin.library_dialog
UI:close(closing);local before=shown;table.remove(queue,1)()
assert(shown==before and not plugin.dav_busy)
-- A late response may update disk but must never reopen a closed view.
plugin:onCloudLibrary();closing=plugin.library_dialog
table.remove(queue,1)();UI:close(closing);before=shown;pending(nil,fresh)
assert(shown==before and plugin.library_dialog==nil and saved==3)
print('Daily local library, manual refresh, offline retention and closed-view lifecycle passed')

-- Covers are fetched only for visible books, then persistently cached by version.
local covers,cover_gets={},0
cache.load_cover=function(_,_,record)
    local v=covers[record.bookId];return v and v.version==record.coverVersion and v.cover
end
cache.save_cover=function(_,_,record,cover)covers[record.bookId]={version=record.coverVersion,cover=cover}end
package.loaded['modules/book_cover'].decode=function(value)return value=='cover' and value end
plugin.dav_adapter.download=function(_,path,_,_,cb)
    cover_gets=cover_gets+1;cb(nil,'{"coverPng":"cover"}')
end
local one={record={bookId='one',coverPath='covers/one.json',coverVersion='1'}}
local two={record={bookId='two',coverPath='covers/two.json',coverVersion='1'}}
cached={backend='fixture',backend_id='backend',entries={one,two},issues={},unpublished={}}
today=true;plugin:onCloudLibrary()
local grid=plugin.library_dialog;grid.visible_entries={one};grid.page=1
grid.result.load_covers(grid);assert(cover_gets==1 and one.coverPng=='cover' and not two.coverPng)
-- A new entry object simulates closing/reopening or restarting with disk cache.
local again={record=one.record};grid.visible_entries={again};grid.result.load_covers(grid)
assert(cover_gets==1 and again.coverPng=='cover')
local changed={record={bookId='one',coverPath='covers/one.json',coverVersion='2'}}
grid.visible_entries={changed};grid.result.load_covers(grid);assert(cover_gets==2)
grid.visible_entries={two};grid.result.load_covers(grid);assert(cover_gets==3)
print('Visible-page cover loading, cache reuse and per-book cover invalidation passed')
