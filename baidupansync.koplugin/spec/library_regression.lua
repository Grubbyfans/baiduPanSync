-- Isolated grid regression; run from repository root with Lua/LuaJIT.
package.path='baidupansync.koplugin/?.lua;'..package.path
local shown,current,selected,freed
local width,height=600,800
local Widget={}
function Widget:extend(o)return setmetatable(o,{__index=self})end
function Widget:new(o)
    o=setmetatable(o or {},{__index=self})
    if o.init then o:init()end
    return o
end
function Widget:getSize()
    if self.dimen then return self.dimen end
    if self.kind=='titlebar' then return {w=self.width,h=50}end
    if self.kind=='buttontable' then return {w=self.width,h=50}end
    if self.kind=='verticalspan' then return {w=0,h=self.width}end
    if self.kind=='horizontalspan' then return {w=self.width,h=0}end
    if self.kind=='verticalgroup' or self.kind=='horizontalgroup' then
        local w,h=0,0
        for _,child in ipairs(self)do local s=child:getSize()
            if self.kind=='verticalgroup' then w=math.max(w,s.w);h=h+s.h
            else w=w+s.w;h=math.max(h,s.h)end
        end
        return {w=w,h=h}
    end
    if self.width and self.height then return {w=self.width,h=self.height}end
    if self[1]then return self[1]:getSize()end
    return {w=self.width or 0,h=self.height or 0}
end
function Widget:free()
    for _,child in ipairs(self)do child:free()end
    if self.image then self.image:free()end
end
function Widget:onShowKeyboard()end
function Widget:getInputText()return self.input end
function Widget:setText(text)self.text=text end
local UI={show=function(_,w)shown=w end,close=function(_,w)
    if w.onCloseWidget then w:onCloseWidget()else w.closed=true end;w:free()
end,setDirty=function()end}
package.loaded['ui/uimanager']=UI
for _,name in ipairs({'container/inputcontainer','container/centercontainer','container/framecontainer',
    'verticalgroup','horizontalgroup','verticalspan','horizontalspan','textboxwidget','imagewidget',
    'titlebar','buttontable','buttondialog','confirmbox','inputdialog','multiinputdialog','qrwidget'})do
    package.loaded['ui/widget/'..name]=Widget:extend{kind=name}
end
package.loaded['ui/geometry']=Widget
package.loaded['ui/gesturerange']=Widget
package.loaded['ui/font']={getFace=function()return {}end}
package.loaded.device={screen={getWidth=function()return width end,getHeight=function()return height end}}
package.loaded['ffi/blitbuffer']={COLOR_WHITE=255,COLOR_LIGHT_GRAY=192}
package.loaded['modules/book_cover']={render=function(encoded)
    if encoded=='cover' then return {getWidth=function()return 120 end,getHeight=function()return 160 end,
        free=function()freed=(freed or 0)+1 end}end
end}
package.loaded['ui/progress_dialog']={info=function()end}
package.loaded.gettext=function(s)return s end
package.loaded['modules/book_metadata']={filename=function(r)return r.fileName end,
    text=function(s)return type(s)=='string' and #s>0 end,name=function(s)return s..'.epub' end}
local Cloud=require('ui/cloud_dialog')
local Grid=require('ui/library_grid')
local result={entries={},issues={},backend='http://test/sync/'}
for i=1,18 do result.entries[i]={record={fileName='book'..i..'.epub',
    title=string.format('书籍%02d',i),size=i*1024,bookId=string.rep('a',64),coverPng=i==1 and 'cover' or nil}}end
local function open(r,page,state)
    return Cloud.library(r,function(e)selected=e end,page,function(w)current=w end,
        function(w)if current==w then current=nil end end,state)
end
local grid=open(result)
assert(grid.layout_info.cols==3 and grid.pages==2 and #grid.visible_entries==9)
assert(grid.visible_entries[1]==result.entries[1])
grid:select(grid.visible_entries[1])
assert(selected==nil and shown.title:find('book1.epub',1,true) and not grid.closed)
assert(shown.buttons[1][1].text=='下载书籍')
shown.buttons[3][1].callback();assert(selected==nil,'returning from details must not download')
grid:select(grid.visible_entries[1]);assert(selected==nil)
shown.buttons[1][1].callback();assert(selected==result.entries[1] and not grid.closed)
grid:goToPage(2)
assert(grid==current and grid.page==2 and grid.visible_entries[1]==result.entries[10])
assert(freed==1,'previous page must release its cover image')
grid:onSwipe(nil,{direction='east'});assert(grid.page==1)
grid:options();shown.buttons[2][1].callback()
assert(grid.state.order=='size' and grid.visible_entries[1]==result.entries[18])
assert(result.entries[1].record.fileName=='book1.epub')
grid:search();shown.input='书籍03';shown.buttons[1][3].callback()
assert(grid.pages==1 and #grid.visible_entries==1 and grid.visible_entries[1]==result.entries[3])
grid:details(grid.visible_entries[1]);assert(shown.title:find('book3.epub',1,true))
shown.buttons[1][1].callback();assert(selected==result.entries[3] and not grid.closed)
local deleted
grid.on_delete=function(entry)deleted=entry end
grid:details(grid.visible_entries[1]);shown.buttons[2][1].callback()
assert(deleted==result.entries[3] and not grid.closed)
result.entries[3].incomplete=true;selected=nil
grid:select(result.entries[3])
assert(selected==nil and shown.buttons[1][1].enabled==false and shown.title:find('EPUB 缺失',1,true))
shown.buttons[2][1].callback();assert(deleted==result.entries[3])
result.entries[3].incomplete=nil
local choice
Cloud.confirm({kind='delete_book',backend='fixture',record=result.entries[3].record,
    paths={'books/fixture.epub','metadata/fixture.json','progress/fixture.json'},best_effort=true},function(v)choice=v end)
assert(shown.text:find('本机已下载文件',1,true) and shown.text:find('无法原子锁定',1,true))
shown.cancel_callback();assert(choice==false)
local orphan={book_id=string.rep('a',64),path='books/'..string.rep('a',64)..'.epub',size=1024}
grid.result.unpublished={orphan};local repaired,refreshed
grid.on_repair=function(entry)repaired=entry end;grid.on_refresh=function()refreshed=true end
grid:options();shown.buttons[4][1].callback();shown.buttons[1][1].callback();shown.buttons[1][1].callback()
assert(repaired==orphan and not grid.closed)
grid:options();shown.buttons[3][1].callback();assert(refreshed)
Cloud.confirm({kind='repair_book',backend='fixture',entry=orphan},function(v)choice=v end)
shown.input='中文书名';shown.buttons[1][2].callback();assert(choice.title=='中文书名')
grid:updateResult(result);assert(grid.state.query=='书籍03' and #grid.visible_entries==1)
grid.state.query='missing';grid:rebuild();assert(#grid.visible_entries==0 and grid.pages==1)
grid:goToPage(999);assert(grid.page==1)
grid.state.query='';grid.state.order='name';grid:rebuild()
width,height=800,600;grid:onSetDimensions()
assert(grid.layout_info.cols==4 and grid.layout_info.rows==2 and #grid.visible_entries==8)
for _,size in ipairs({{600,800},{1072,1448},{800,600},{300,400}})do
    local layout=Grid.layout(size[1],size[2],100,50)
    assert(layout.cell_w*layout.cols+layout.gap*(layout.cols+1)<=size[1])
    assert(layout.cell_h*layout.rows+layout.gap*(layout.rows+1)+150<=size[2])
end
grid:close();assert(current==nil and grid.closed)
local page=grid.page;grid:goToPage(2);assert(grid.page==page)
local blank=open({entries={},issues={},backend='test'})
assert(blank.pages==1 and #blank.visible_entries==0)
assert(Cloud.library_title{title=' 三国演义 ',fileName='sanguoyanyi.epub'}=='三国演义')
assert(Cloud.library_title{title=' ',fileName='三国演义.epub'}=='三国演义')
assert(#Cloud.library_entries(result,{query='book.'})==0)
assert(Cloud.library_entries(result,{query='book3'})[1]==result.entries[3])
print('cover grid, search, sorting, navigation and resource regressions passed')
local QRPage=require('ui/baidu_auth_dialog')
local cancelled,code=0,nil
local qr=QRPage:new{session={url='http://192.168.1.2:1234/authorize/fixture'},
    on_cancel=function()cancelled=cancelled+1 end,on_code=function(v)code=v end}
qr:update(599,'waiting');assert(qr.status.text:find('9:59',1,true))
qr:manual();shown.input='fixture-code';shown.buttons[1][2].callback();assert(code=='fixture-code')
qr:close();qr:close();assert(cancelled==1)
local setup=QRPage:new{session={url='http://192.168.1.2:1234/authorize/fixture',state='configuring'},
    on_cancel=function()end,on_code=function()error('configuration must precede manual code entry')end}
setup:update(590,'configuring');assert(setup.status.text:find('填写资料',1,true))
setup:manual()
setup.session.state='waiting';setup:update(580,'waiting')
assert(setup.mode=='waiting' and setup.status.text:find('等待手机提交',1,true))
setup:close()
print('Baidu QR page countdown, manual fallback and close lifecycle regressions passed')
local BaiduUI=require('ui/baidu_dialog')
local state={data={activeBackendType='webdav',activeBackendId='dav-id'}}
local credential={backend_id='baidu-id',last_probe={backend_id='baidu-id'},expires_at=os.time()+3600}
local plugin={baidu_store={load=function()return credential end},
    config={_read=function()return state end,_write=function()return true end},
    dav_adapter={backend_id='dav-id'},refreshHome=function()end}
BaiduUI.switch_backend(plugin);assert(shown.buttons[2][1].enabled)
shown.buttons[2][1].callback()
assert(plugin.active_backend=='baidu' and state.data.activeBackendId=='baidu-id')
BaiduUI.switch_backend(plugin);shown.buttons[1][1].callback()
assert(plugin.active_backend=='webdav' and state.data.activeBackendId=='dav-id')
credential.expires_at=0;BaiduUI.switch_backend(plugin)
assert(not shown.buttons[2][1].enabled)
print('Explicit backend selection and expired-auth gating regressions passed')
