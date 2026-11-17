package.path='baidupansync.koplugin/?.lua;'..package.path
local modes={}
local ffi={cdef=function()end,C={chmod=function(_,mode)modes[mode]=true;return 0 end}}
package.loaded.ffi=ffi
package.loaded['libs/libkoreader-lfs']={attributes=function(path,key)
    local a=fixture_attributes(path);return key and a and a[key] or a
end,symlinkattributes=function(path,key)
    local a=fixture_attributes(path);return key and a and a[key] or a
end,mkdir=fixture_mkdir}
package.loaded['ffi/util']={fsyncOpenedFile=function()end}
package.loaded['modules/random']={hex=function(n)return string.rep('a',n*2)end}
local Store=require('modules/baidu_store')
local store=Store:new{dir=fixture_temp_dir}
local p={app_key='app',secret_key='fixture-secret',app_dir='/apps/测试'}
assert(not store:load())
assert(store:save(p));assert(store:load().secret_key=='fixture-secret')
assert(modes[448] and modes[384],'private directory and file permissions must be requested')
local function read()
    local f=assert(io.open(store.file,'rb'));local raw=f:read('*a');f:close();return raw
end
local before=read()
ffi.C.chmod=function()return -1 end
local ok,e=store:save(p);assert(not ok and e.code=='IO' and read()==before)
ffi.C.chmod=function()return 0 end
local rename=os.rename;os.rename=function()return nil end
ok,e=store:save(p);os.rename=rename
assert(not ok and e.code=='IO' and read()==before)
local f=assert(io.open(store.file,'wb'));f:write('{broken');f:close()
ok,e=store:save(p);assert(not ok and e.code=='UNSUPPORTED' and read()=='{broken')
local state={schemaVersion=1,data={activeBackendType='baidu',activeBackendId='baidu-id'}}
local config={_read=function()return state end,_write=function()return true end}
local webdav=require('modules/backend_store'):new{dir=fixture_temp_dir,config=config}
local profile={type='webdav',root_url='http://example.test/sync/',username='fixture-user',password='fixture-password'}
assert(webdav:save(profile));assert(state.data.activeBackendId=='baidu-id')
assert(webdav:load().password=='fixture-password' and read()=='{broken')
state.data.activeBackendType='webdav';assert(webdav:save(profile))
assert(state.data.activeBackendId~='baidu-id')
print('Baidu private atomic credential storage and failure preservation regressions passed')
