package.path='baidupansync.koplugin/?.lua;'..package.path
package.loaded['libs/libkoreader-lfs']={}
package.loaded['modules/random']={hex=function(n)return string.rep('a',n*2)end}
local API=require('modules/baidu_api')
local Server=require('modules/baidu_auth_server')
local Probe=require('modules/baidu_probe')
local E=require('modules/errors')
local json=require('json')
local root='/apps/测试'
local files,dirs={}, {[root]=true}
local pending,uploaded,calls,bad_link
calls=0
package.loaded['socket.url']={parse=function(url)
    local scheme,host=url:match('^(https?)://([^/]+)')
    return {scheme=scheme,host=host}
end,absolute=function(_,url)return url end}
local function transport(req,done)
    calls=calls+1
    assert(req.headers['User-Agent']=='pan.baidu.com')
    local endpoint,query=req.url:match('^https://[^/]+([^?]+)%?(.*)$')
    local q=assert(Server.form(query));local body=req.body and Server.form(req.body) or {}
    local result={errno=0}
    if endpoint=='/rest/2.0/xpan/nas' then
        result.uk='9007199254740993123';result.netdisk_name='测试用户'
    elseif q.method=='list' then
        if not dirs[q.dir] then result.errno=-9
        else
            result.list={}
            for path,file in pairs(files)do
                if path:match('^(.*)/[^/]+$')==q.dir then
                    result.list[#result.list+1]={path=path,fs_id=file.id,size=#file.raw,isdir=0}
                end
            end
        end
    elseif q.method=='create' and body.isdir=='1' then
        assert(req.writing and body.path:sub(1,#root+1)==root..'/')
        dirs[body.path]=true;result.path=body.path
    elseif q.method=='precreate' then
        assert(body.rtype=='3' and body.autoinit=='1' and req.writing)
        pending=body;result.return_type=1;result.uploadid='upload-id';result.block_list={0}
    elseif q.method=='locateupload' then
        assert(q.uploadid=='upload-id' and q.path==pending.path)
        result={error_code=0,servers={{server='https://fixture.pcs.baidu.com'}}}
    elseif q.method=='upload' then
        assert(q.uploadid=='upload-id' and q.partseq=='0' and q.type=='tmpfile')
        uploaded=req.body:match('\r\n\r\n(.-)\r\n%-%-bps%-')
        assert(uploaded);result.md5=require('ffi/sha2').md5(uploaded)
    elseif q.method=='create' then
        assert(body.path==pending.path and #uploaded==tonumber(body.size) and req.writing)
        files[body.path]={raw=uploaded,id='9007199254740993456'}
        result.path=body.path;result.size=#uploaded;result.fs_id='9007199254740993456'
    elseif q.method=='filemetas' then
        assert(q.fsids=='[9007199254740993456]')
        local path=next(files)
        result.list={{path=path,fs_id=files[path].id,size=#files[path].raw,
            dlink=bad_link or 'https://d.pcs.baidu.com/probe?sign=signature'}}
    elseif endpoint=='/probe' then
        return done(nil,{status=302,headers={location='https://cdn.baidupcs.com/bytes?sign=signed'},body=''})
    elseif endpoint=='/bytes' then
        local path=next(files);return done(nil,{status=200,body=files[path].raw})
    elseif q.method=='filemanager' then
        assert(q.opera=='delete' and body.async=='0' and req.writing)
        local list=json.decode(body.filelist);assert(#list==1 and files[list[1]])
        files[list[1]]=nil;result.info={{errno=0,path=list[1]}}
    else error('unexpected fixture endpoint')end
    done(nil,{status=200,body=json.encode(result)})
end
local api=assert(API:new{app_dir=root,app_key='app',user_id='9007199254740993123',access_token='token',
    expires_at=10000,now=function()return 1000 end,transport=transport})
local count=0
Probe.run(api,function(e,r)
    assert(not e,e and e.message)
    assert(r.user_id=='9007199254740993123' and r.directory:find('/c2-probe-',1,true))
    count=count+1
end)
assert(count==1 and calls>10 and next(files)==nil)
api:mkdir('c2-probe-aa',function(e)assert(not e)end)
api:uploadSmallJson('c2-probe-aa/probe.json','{"test":1}',nil,function(e)assert(not e,e and e.message)end)
bad_link='https://evil.example/probe'
api:download('c2-probe-aa/probe.json',function(e)assert(e.code=='INVALID_INPUT')end)
local before=calls
api:delete('other/real.epub',nil,function(e)assert(e.code=='FORBIDDEN')end)
assert(calls==before)
api.transport=function(_,done)done(E.new('UNCERTAIN','cancelled write',{outcome='uncertain'}))end
api:mkdir('c2-probe-bb',function(e)assert(e.code=='UNCERTAIN')end)
print('Baidu C2 mkdir/upload/list/dlink/redirect/delete probe and containment regressions passed')
