package.path='baidupansync.koplugin/?.lua;'..package.path
local open=io.open
local allowed={}
local mock=true
package.loaded['libs/libkoreader-lfs']={attributes=function(path,key)
    if mock then return allowed[path] and 'file' or nil end
    local a=fixture_attributes(path);return a and a[key]
end}
local TLS=require('modules/dav_tls')
io.open=function(path,mode)
    if allowed[path] then return {read=function()return 'x' end,close=function()end} end
    return nil
end
local own='baidupansync.koplugin/resources/ca-bundle.crt'
allowed[own]=true
assert(TLS.ca_file(nil,{})==own,'older LuaSec must use the bundled fallback')
assert(TLS.ca_file('',{get_system_ca=function()return nil end})==own)
assert(TLS.ca_file(nil,{get_system_ca=function()error('unsupported')end})==own)
assert(TLS.ca_file(nil,{get_system_ca=function()return {}end})==own)
allowed['data/ca-bundle.crt']=true
assert(TLS.ca_file(nil,{})=='data/ca-bundle.crt')
allowed['/fixture/system.pem']=true
assert(TLS.ca_file(nil,{get_system_ca=function()return '/fixture/system.pem' end})=='/fixture/system.pem')
allowed['/fixture/custom.pem']=true
assert(TLS.ca_file('/fixture/custom.pem',{})=='/fixture/custom.pem')
local value,e=TLS.ca_file('/missing/custom.pem',{})
assert(not value and e:find('指定的 CA',1,true),'explicit paths must not silently fall back')
allowed={}
assert(not TLS.ca_file(nil,{}))
io.open=open
mock=false
-- Check the real package fallback is actually present and readable.
assert(TLS.ca_file(nil,{}))
local parameters
package.loaded.ssl={wrap=function(sock,p)
    parameters=p
    return {settimeout=function()end,sni=function()return true end,dohandshake=function()return true end,
        getpeercertificate=function()return {}end}
end}
package.loaded.socket={tcp=function()return {connect=function()return true end}end}
local matches=TLS.matches;TLS.matches=function()return true end
local factory=assert(TLS.factory())
assert(factory():connect('openapi.baidu.com',443))
assert(parameters.verify=='peer' and parameters.cafile and parameters.options[5]=='no_tlsv1_1')
TLS.matches=function()return false end
package.loaded.ssl.wrap=function()
    return {settimeout=function()end,sni=function()return true end,dohandshake=function()return true end,
        getpeercertificate=function()return {}end,close=function()end}
end
local connected,reason=factory():connect('wrong.invalid',443)
assert(not connected and reason=='SAN identity mismatch')
TLS.matches=matches
print('CA discovery, bundled fallback, explicit-path isolation and peer/SAN verification regressions passed')
