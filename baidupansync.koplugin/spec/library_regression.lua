-- Isolated library UI regression; run from repository root with Lua/LuaJIT.
package.path='baidupansync.koplugin/?.lua;'..package.path
local shown,info
local widget={}
function widget:new(o)return setmetatable(o,{__index=self})end
function widget:onShowKeyboard()end
function widget:getInputText()return self.input end
local UI={show=function(_,w)shown=w end,close=function(_,w)
    w.closed=true;if w.onCloseWidget then w:onCloseWidget()end
end}
package.loaded['ui/uimanager']=UI
for _,name in ipairs({'buttondialog','confirmbox','inputdialog'}) do
    package.loaded['ui/widget/'..name]=widget
end
package.loaded['ui/progress_dialog']={info=function(text)info=text end}
package.loaded.gettext=function(s)return s end
package.loaded['modules/book_metadata']={filename=function(r)return r.fileName end}
local Cloud=require('ui/cloud_dialog')
local result={entries={},issues={},backend='http://test/sync/'}
for i=1,9 do result.entries[i]={record={fileName='book'..i..'.epub',title='书籍'..i,size=i*1024,bookId=string.rep(tostring(i),64)}}end
local selected,current
local function show(w)current=w end
local function close(w)if current==w then current=nil end end
local function open(r,page,state)return Cloud.library(r,function(e)selected=e end,page,show,close,state)end
local first=open(result)
assert(first.title:find('1 / 2',1,true))
assert(not first.title:find(result.backend,1,true))
assert(first.buttons[2][1].text:find('book1',1,true))
assert(not first.buttons[2][1].text:find(string.rep('1',8),1,true))
first.buttons[2][1].callback();assert(selected==result.entries[1] and not first.closed)
first.buttons[#first.buttons-1][2].callback()
assert(first.closed and current==shown and shown.title:find('2 / 2',1,true))
shown.buttons[2][1].callback();assert(selected==result.entries[7])
shown.buttons[1][2].callback() -- largest first, resets pagination
assert(shown.title:find('1 / 2',1,true))
shown.buttons[2][1].callback();assert(selected==result.entries[9])
assert(result.entries[1].record.fileName=='book1.epub','sorting must not mutate the snapshot')
shown.buttons[1][1].callback();local input=shown
input.input='书籍3';input.buttons[1][3].callback()
assert(current==shown and shown.title:find('1 本',1,true))
shown.buttons[2][1].callback();assert(selected==result.entries[3])
local empty=open(result,99,{query='missing',order='name'})
assert(empty.title:find('未找到匹配',1,true) and empty.title:find('1 / 1',1,true))
empty.buttons[1][1].callback();shown.buttons[1][2].callback()
assert(current.title:find('9 本',1,true))
local filtered=Cloud.library_entries(result,{query='book.',order='name'})
assert(#filtered==0,'search must treat punctuation literally')
result.entries[2].record.fileName='book1.epub'
local duplicates=open(result)
assert(duplicates.buttons[2][1].text:find('版本',1,true))
result.issues={{path='metadata/broken.json'}}
local warning=open(result)
assert(warning.title:find('异常记录',1,true))
warning.buttons[#warning.buttons][1].callback()
assert(info:find('metadata/broken.json',1,true))
warning.buttons[#warning.buttons][2].callback();assert(current==nil)
local blank=open({entries={},issues={},backend='test'})
assert(blank.title:find('书库为空',1,true))
print('library search, sorting and pagination regressions passed')
