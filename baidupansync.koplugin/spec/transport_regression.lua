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
print('Shared transport credential isolation and cancelled-write outcome regressions passed')
