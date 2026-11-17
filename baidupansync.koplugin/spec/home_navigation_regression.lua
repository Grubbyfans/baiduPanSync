-- Isolated navigation regression; run from repository root with Lua/LuaJIT.
package.path='baidupansync.koplugin/?.lua;'..package.path
local Menu={}
function Menu:extend(o)return setmetatable(o,{__index=self})end
function Menu:init()end
function Menu:switchItemTable(title,items,selected,_,subtitle)
    self.item_table=items;self.itemnumber=selected;self.subtitle=subtitle
    for i,item in ipairs(items)do item.idx=i end
end
function Menu:onClose()self.closed=true end
package.loaded['ui/widget/menu']=Menu
package.loaded['ui/uimanager']={}
package.loaded.gettext=function(s)return s end
local Home=require('ui/home_page')
local calls={}
local plugin={ui={},dav_adapter={},dav_profile={},
    isCurrentBookSupported=function()return true end,hasRestorePoint=function()return true end}
for _,method in ipairs({'onCloudLibrary','onUploadBook','onQueryCloudProgress','onUploadCloudProgress',
    'onDownloadCloudProgress','onUndoRestore'})do
    local name=method
    plugin[name]=function()calls[name]=(calls[name]or 0)+1 end
end
local page=Home:extend{plugin=plugin,page=1,perpage=6}
page:init();page:refresh()
local function select(index)page:onMenuSelect(page.item_table[index])end
assert(#page.item_table==4)
select(1);assert(calls.onCloudLibrary==1)
select(2);assert(calls.onUploadBook==1)
select(3);assert(page.section=='progress' and #page.item_table==5)
select(2);select(3);select(4);select(5)
assert(calls.onQueryCloudProgress==1 and calls.onUploadCloudProgress==1)
assert(calls.onDownloadCloudProgress==1 and calls.onUndoRestore==1)
page:onClose();assert(not page.section and not page.closed)
select(4);assert(page.section=='settings' and #page.item_table==3)
assert(page.item_table[2].select_enabled and page.item_table[3].select_enabled)
plugin.dav_adapter=nil;page:refresh()
assert(page.item_table[2].select_enabled and not page.item_table[3].select_enabled)
select(1);assert(not page.item_table[1].select_enabled)
plugin.dav_busy=true;page:refresh();select(2);assert(calls.onUploadBook==1)
select(3);assert(page.section=='progress')
select(3);assert(calls.onUploadCloudProgress==1)
plugin.dav_busy=false;plugin.dav_adapter={}
plugin.isCurrentBookSupported=function()return false end
page:refresh()
for i=2,5 do assert(not page.item_table[i].select_enabled)end
page:onClose();page:onClose();assert(page.closed)
print('grouped home navigation regressions passed')
