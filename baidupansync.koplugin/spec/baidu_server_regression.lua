package.path='baidupansync.koplugin/?.lua;'..package.path
package.loaded['libs/libkoreader-lfs']={}
local hooks={}
package.loaded['ffi/util']={addRunInSubProcessAfterForkFunc=function(key,fn)hooks[key]=fn end,
    removeRunInSubProcessAfterForkFunc=function(key)hooks[key]=nil end}
local Server=require('modules/baidu_auth_server')
assert(Server.private_ip('192.168.1.2') and Server.private_ip('10.1.2.3') and Server.private_ip('172.16.1.2'))
assert(not Server.private_ip('127.0.0.1') and not Server.private_ip('8.8.8.8') and not Server.private_ip('192.168.1.999'))
local listener={settimeout=function()end,bind=function()return true end,listen=function()return true end,
    getsockname=function()return '192.168.1.2',12345 end,accept=function()return nil end,
    close=function(self)self.closed=true end}
local now,submitted,done=1000,0,nil
local server=assert(Server.start{ip='192.168.1.2',app_key='app',
    socket={tcp=function()return listener end,gettime=function()return now end},
    random=function(n)return string.rep('a',n*2)end,on_code=function(code,cb)
        assert(code=='auth-code');submitted=submitted+1;done=cb
    end})
assert(next(hooks),'HTTP listener must register subprocess descriptor cleanup')
local function request(method,path,headers,body)
    body=body or '';headers=headers or {}
    local raw=method..' '..path..' HTTP/1.1\r\nHost: '..server.authority..'\r\n'
    for k,v in pairs(headers)do raw=raw..k..': '..v..'\r\n'end
    return raw..'Content-Length: '..#body..'\r\n\r\n'..body
end
local status,html=server:parse(request('GET',server.path))
assert(status==200 and html:find('前往百度授权',1,true))
assert(not html:find('client_secret',1,true) and not html:find('localStorage',1,true))
assert(server:parse(request('GET','/wrong'))==404)
assert(server:parse(request('POST',server.path,{Origin='https://evil.test'},'code=x'))==403)
assert(server:parse(request('POST',server.path,{['Content-Type']='application/x-www-form-urlencoded'},'code=x&csrf=bad'))==400)
local body='code=auth-code&csrf='..server.csrf
local raw=request('POST',server.path,{['Content-Type']='application/x-www-form-urlencoded'},body)
assert(server:parse(raw:sub(1,-2))==nil)
assert(server:parse(raw)==202 and submitted==1)
assert(server:parse(raw)==409 and submitted==1)
assert(server:parse(request('GET',server.path..'/status'))==200)
done(nil);assert(server.state=='success')
local _,message=server:parse(request('GET',server.path..'/status'))
assert(message:find('授权成功',1,true))
assert(server:parse('POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 99999\r\n\r\n')==413)
assert(server:parse('POST / HTTP/1.1\r\nHost: x\r\nHost: y\r\n\r\n')==400)
assert(server:parse('GET / HTTP/1.1\r\n'..string.rep('x',4096))==431)
now=1006;server:poll_once();assert(server.closed and listener.closed and not server.csrf and next(hooks)==nil)
assert(Server.form('code=a%ZZ')==nil and Server.form('code=a&code=b')==nil)
local configured,configuration_error=0,true
local err=require('modules/errors').new('IO','fixture save failure')
listener.closed=false
server=assert(Server.start{ip='192.168.1.2',app_key=nil,
    socket={tcp=function()return listener end,gettime=function()return now end},
    random=function(n)return string.rep('b',n*2)end,
    public_profile={app_key='existing',app_dir='/apps/测试',has_secret=true,secret_key='never-return-this'},
    on_config=function(fields)
        configured=configured+1;assert(fields.secret_key=='fixture-secret' and fields.app_key=='new-key')
        if configuration_error then return nil,err end
        return 'https://openapi.baidu.com/oauth/2.0/authorize?client_id=new-key&redirect_uri=oob'
    end,on_code=function(code,cb)assert(code=='auth-code');cb(nil)end})
status,html=server:parse(request('GET',server.path))
assert(status==200 and server.state=='configuring' and html:find('保存并继续授权',1,true))
assert(not html:find('never-return-this',1,true))
local config_body=require('modules/baidu_http').form{app_key='new-key',secret_key='fixture-secret',app_dir='/apps/测试',csrf=server.csrf}
local config_request=request('POST',server.path..'/config',{['Content-Type']='application/x-www-form-urlencoded'},config_body)
assert(server:parse(request('GET',server.path..'/config'))==405)
local bad_config_body=config_body:gsub('csrf='..server.csrf,'csrf=bad')
assert(server:parse(request('POST',server.path..'/config',{['Content-Type']='application/x-www-form-urlencoded'},bad_config_body))==400 and configured==0)
assert(server:parse(config_request)==400 and configured==1 and server.state=='configuring')
configuration_error=false
assert(server:parse(config_request)==200 and configured==2 and server.state=='waiting')
assert(server:parse(config_request)==409 and configured==2)
status,html=server:parse(request('GET',server.path))
assert(status==200 and html:find('前往百度授权',1,true) and not html:find('fixture-secret',1,true))
assert(server:parse(request('POST',server.path,{['Content-Type']='application/x-www-form-urlencoded'},
    'code=auth-code&csrf='..server.csrf))==202)
assert(server.state=='success');server:stop('test_cleanup')
print('LAN auth HTTP parsing, CSRF, replay, request limits and lifecycle regressions passed')
