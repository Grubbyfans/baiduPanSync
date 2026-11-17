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
local UI={show=function(_,w)shown=w end,close=function(_,w)
    if w.onCloseWidget then w:onCloseWidget()else w.closed=true end;w:free()
end,setDirty=function()end}
package.loaded['ui/uimanager']=UI
for _,name in ipairs({'container/inputcontainer','container/centercontainer','container/framecontainer',
    'verticalgroup','horizontalgroup','verticalspan','horizontalspan','textboxwidget','imagewidget',
    'titlebar','buttontable','buttondialog','confirmbox','inputdialog'})do
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
package.loaded['modules/book_metadata']={filename=function(r)return r.fileName end}
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
grid:select(grid.visible_entries[1]);assert(selected==result.entries[1] and not grid.closed)
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
