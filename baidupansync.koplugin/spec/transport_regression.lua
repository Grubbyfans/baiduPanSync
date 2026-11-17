package.path='baidupansync.koplugin/?.lua;'..package.path
local captured,fail=false,false
package.loaded.socket={gettime=function()return 0 end}
package.loaded['socket.http']={request=function(req)
    captured=req
    if fail then return nil,'fixture failure' end
    req.sink('{}');return 1,200,{}
end}
package.loaded.ltn12={source={string=function()return function()return nil end end}}
package.loaded.socketutil={set_timeout=function()end,reset_timeout=function()end}
package.loaded['ui/uimanager']={}
package.loaded['ui/trapper']={wrap=function(_,fn)fn()end,dismissableRunInSubprocess=function()return false end}
local Transport=require('modules/dav_transport')
local e,r=Transport.perform{url='http://fixture/',method='GET',username='user',password='password'}
assert(not e and r.status==200 and captured.headers.Authorization=='Basic dXNlcjpwYXNzd29yZA==')
e,r=Transport.perform{url='http://fixture/',method='GET'}
assert(not e and captured.headers.Authorization==nil,'Baidu requests must not send WebDAV credentials')
fail=true
e=Transport.perform{url='http://fixture/',method='POST',writing=true}
assert(e.code=='UNCERTAIN' and e.outcome=='uncertain')
Transport.request({url='http://fixture/',method='POST',writing=true},function(err)assert(err.code=='UNCERTAIN')end)
Transport.request({url='http://fixture/',method='GET'},function(err)assert(err.code=='CANCELLED')end)
-- A crashed/empty child result used to become a nil-index exception in Baidu.
local trapper=package.loaded['ui/trapper']
trapper.dismissableRunInSubprocess=function()return true end
Transport.request({url='http://fixture/',method='GET'},function(err)assert(err.code=='NETWORK')end)
Transport.request({url='http://fixture/',method='POST',writing=true},function(err)assert(err.code=='UNCERTAIN')end)
local original=Transport.perform
Transport.perform=function()error('dav_transport.lua:68: bad argument https://fixture/?access_token=SECRET')end
trapper.dismissableRunInSubprocess=function(_,fn)return true,fn()end
local count=0
Transport.request({url='http://fixture/',method='GET'},function(err)
    count=count+1;assert(err.code=='IO' and err.message:find('dav_transport.lua:68',1,true))
    assert(not err.message:find('SECRET',1,true) and not err.message:find('https://',1,true))
end)
assert(count==1)
Transport.perform=original
trapper.dismissableRunInSubprocess=function()error('fixture parent exception with SecretKey=SECRET')end
Transport.request({url='http://fixture/',method='POST',writing=true},function(err)
    assert(err.code=='UNCERTAIN' and not err.message:find('SECRET',1,true))
end)
-- Protected parent handling must still allow Trapper to yield and resume.
trapper.dismissableRunInSubprocess=function()return coroutine.yield()end
local resumed=0
local co=coroutine.create(function()
    Transport.request({url='http://fixture/',method='GET'},function(err,response)
        assert(not err and response.status==200);resumed=resumed+1
    end)
end)
assert(coroutine.resume(co));assert(resumed==0)
assert(coroutine.resume(co,true,nil,{status=200}));assert(resumed==1 and coroutine.status(co)=='dead')
print('Shared transport credential isolation and cancelled-write outcome regressions passed')
