package.path='baidupansync.koplugin/?.lua;'..package.path
package.loaded['libs/libkoreader-lfs']={}
local H=require('modules/baidu_http')
local API=require('modules/baidu_api')
local Auth=require('modules/baidu_auth')
local json=require('json')
local E=require('modules/errors')
assert(H.decode('{"uk":9007199254740993123,"fs_id":9007199254740993456}').uk=='9007199254740993123')
assert(not API.root('/apps/a/../../b'))
assert(not API.root('/outside'))
local now=1000
local profile={app_key='app',secret_key='secret',app_dir='/apps/测试'}
local saved,save_count=nil,0
local store={save=function(_,v)saved=v;save_count=save_count+1;return true end}
local function token()
    return {status=200,body=json.encode{access_token='token',expires_in=3600,scope='basic netdisk',refresh_token='refresh'}}
end
local function transport(req,done)
    assert(req.url:sub(1,8)=='https://')
    if req.url:find('/oauth/2.0/token',1,true) then
        assert(req.url:find('redirect_uri=oob',1,true));done(nil,token())
    else done(nil,{status=200,body='{"errno":0,"uk":9007199254740993123,"netdisk_name":"测试用户"}'})end
end
local auth=Auth:new{profile=profile,store=store,transport=transport,now=function()return now end,deadline=1600}
local count=0
auth:submit('code',function(e,result)
    assert(not e and result.user_id=='9007199254740993123');count=count+1
end)
assert(count==1 and save_count==1 and saved.expires_at==4600 and saved.secret_key=='secret')
assert(not profile.access_token and saved.backend_id)
auth:submit('again',function(e)assert(e.code=='CONFLICT')end)
local callback
auth=Auth:new{profile=profile,store=store,transport=function(_,cb)callback=cb end,
    now=function()return now end,deadline=1600}
auth:submit('code',function(e)assert(e.code=='CANCELLED')end)
auth:cancel();callback(nil,token());assert(save_count==1)
auth=Auth:new{profile=profile,store=store,transport=function(_,cb)callback=cb end,
    now=function()return now end,deadline=1600}
auth:submit('code',function(e)assert(e.code=='CANCELLED')end)
now=1601;callback(nil,token());assert(save_count==1);now=1000
auth=Auth:new{profile=profile,store=store,transport=function(_,cb)
    cb(nil,{status=200,body='{"access_token":"token","expires_in":3600,"scope":"basic"}'})
end,now=function()return now end,deadline=1600}
auth:submit('code',function(e)assert(e.code=='AUTH')end);assert(save_count==1)
auth=Auth:new{profile=profile,store={save=function()return nil,E.new('IO','write failed')end},
    transport=transport,now=function()return now end,deadline=1600}
auth:submit('code',function(e)assert(e.code=='IO')end)
local requested=false
local api=assert(API:new{app_key='app',app_dir='/apps/测试',user_id='9007199254740993123',access_token='token',
    expires_at=900,now=function()return now end,transport=function()requested=true end})
api:user_info(function(e)assert(e.code=='AUTH')end);assert(not requested)
assert(api:capabilities().conditional_replace==false)
local ok,err=pcall(api.path,api,'../outside');assert(not ok and err.code=='INVALID_INPUT')
api:uploadSmallJson('test.json','{}',{unconditional=true},function(e)assert(e.code=='AUTH')end)
print('Baidu auth exchange, identity isolation, expiry, cancellation and persistence regressions passed')
