-- Isolated UI regression; run from the repository root with Lua or LuaJIT.
package.path = 'baidupansync.koplugin/?.lua;' .. package.path
local shown, closes = nil, 0
local widget = {}
function widget:new(o) return setmetatable(o, {__index=self}) end
function widget:show() shown=self end
function widget:close()
    closes=closes+1
    -- KOReader may invoke the dismiss callback on programmatic close too.
    if self.dismiss_callback then self.dismiss_callback() end
end
package.loaded['ui/uimanager']={show=function(_,w)shown=w end,close=function(_,w)w:close()end}
for _,name in ipairs({'buttondialog','confirmbox','inputdialog','infomessage','progressbardialog'}) do
    package.loaded['ui/widget/'..name]=widget
end
package.loaded.datetime={}
package.loaded.gettext=function(s)return s end
package.loaded['modules/book_metadata']={}
local Dialog=require('ui/progress_dialog')
local scan=Dialog.start_scan_progress()
scan:close();scan:close()
assert(closes==1, 'scan close must be idempotent')
assert(not scan:is_cancelled(), 'normal scan completion must not cancel download')
scan=Dialog.start_scan_progress()
shown.dismiss_callback()
scan:close()
assert(scan:is_cancelled(), 'explicit user cancellation must be preserved')
local Cloud=require('ui/cloud_dialog')
local count,choice=0,nil
local path='/mnt/onboard/Books/nested/same.epub'
Cloud.confirm({kind='download_book',backend='test',filename='same.epub',
    candidates={{path=path,same=true}}},function(v)count=count+1;choice=v end)
assert(count==0, 'confirmation must wait for the user')
assert(shown.title:find(path,1,true), 'confirmation must show the full local path')
assert(shown.dismissable==false, 'confirmation must require an explicit choice')
shown.buttons[1][1].callback()
assert(count==1 and choice.mode=='overwrite' and choice.path==path)
Cloud.confirm({kind='download_book',backend='test',filename='same.epub',
    candidates={{path=path,same=false}}},function(v)count=count+1;choice=v end)
shown.buttons[#shown.buttons][1].callback()
assert(count==2 and choice=='cancel', 'only explicit cancel should cancel confirmation')
print('scan and download confirmation regressions passed')
