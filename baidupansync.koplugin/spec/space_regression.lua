-- Isolated regression; run from repository root with Lua or LuaJIT.
package.path='baidupansync.koplugin/?.lua;'..package.path
local util={}
package.loaded['ffi/util']=util
package.loaded.ffi={cdef=function()end}
for _,name in ipairs({'libs/libkoreader-lfs','modules/async','modules/random','modules/book_metadata'}) do
    package.loaded[name]={}
end
local Local=require('modules/local_library')
local MiB=1024*1024
local function fails(fn,fragment)
    local ok,err=pcall(fn)
    assert(not ok and err.code=='IO' and err.message:find(fragment,1,true))
end
util.df=function(path)assert(path=='/books');return 100*MiB,20*MiB end
Local.space('/books',2*MiB)
util.df=function()return 100*MiB,20*MiB,10*MiB end
Local.space('/books',2*MiB)
-- Available, not free, determines whether a newer build can proceed.
util.df=function()return 100*MiB,20*MiB,0 end
fails(function()Local.space('/books',2*MiB)end,'可用空间不足')
util.df=function()return 100*MiB,2*MiB end
fails(function()Local.space('/books',2*MiB)end,'可用空间不足')
util.df=function()return nil,'statvfs failed' end
fails(function()Local.space('/books',2*MiB)end,'statvfs failed')
util.df=function()error('unsupported')end
fails(function()Local.space('/books',2*MiB)end,'unsupported')
util.df=function()return 100*MiB,20*MiB,0/0 end
fails(function()Local.space('/books',2*MiB)end,'/books')
print('space compatibility regressions passed')
