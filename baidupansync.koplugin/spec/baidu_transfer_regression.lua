package.path='baidupansync.koplugin/?.lua;'..package.path
package.loaded['libs/libkoreader-lfs']={attributes=fixture_attributes}
local nonce=0
package.loaded['modules/random']={hex=function(n)nonce=nonce+1;return string.format('%0'..(n*2)..'x',nonce)end}
package.loaded['socket.url']={parse=function(url)
    local scheme,host=url:match('^(https?)://([^/]+)');return {scheme=scheme,host=host}
end,absolute=function(_,url)return url end}
local Plan=require('modules/baidu_upload_plan')
local API=require('modules/baidu_api')
local Form=require('modules/baidu_auth_server').form
local sha=require('ffi/sha2')
local json=require('json')
local E=require('modules/errors')
local file=fixture_temp_dir..'/book.epub'
local data=string.rep('PK-book-fixture-',300000) -- > 4 MiB, two unequal slices.
local function write(path,raw)local f=assert(io.open(path,'wb'));f:write(raw);f:close()end
local function read(path)local f=assert(io.open(path,'rb'));local raw=f:read('*a');f:close();return raw end
write(file,data)
local queue,plan={},nil
Plan.file(file,{schedule=function(cb)queue[#queue+1]=cb end},function(e,p)assert(not e);plan=p end)
assert(not plan and #queue==1,'planning must yield before reading a whole EPUB')
while #queue>0 do table.remove(queue,1)()end
assert(plan.size==#data and #plan.blocks==2 and plan.sha256==sha.sha256(data))
assert(plan.parts[1].size==Plan.BLOCK_SIZE and plan.parts[2].offset==Plan.BLOCK_SIZE)
local cancel=false
Plan.file(file,{schedule=function(cb)queue[#queue+1]=cb end,is_cancelled=function()return cancel end},
    function(e)assert(e.code=='CANCELLED')end)
cancel=true;while #queue>0 do table.remove(queue,1)()end
local root='/apps/fixture'
local target='books/'..plan.sha256..'.epub'
local stored,parts,pending,commits={}, {},nil,0
local changed=false
local function transport(req,done)
    local endpoint,query=req.url:match('^https://[^/]+([^?]+)%?(.*)$')
    local q=assert(Form(query));local body=req.body and Form(req.body) or {}
    local response={errno=0}
    if q.method=='list' then
        response.list={}
        for path,r in pairs(stored) do response.list[#response.list+1]={path=path,fs_id='123',size=#r.raw,
            server_mtime=r.revision,md5=sha.md5(r.raw),isdir=0}end
    elseif q.method=='precreate' then
        pending=body
        local blocks=json.decode(body.block_list)
        response.return_type=1;response.uploadid='upload';response.block_list={}
        for i=#blocks,1,-1 do response.block_list[#response.block_list+1]=i-1 end
    elseif q.method=='upload' then
        assert(req.upload_size<=4*1024*1024 and req.upload_prefix and req.upload_suffix)
        local f=assert(io.open(req.upload_path,'rb'));f:seek('set',req.upload_offset)
        local raw=f:read(req.upload_size);f:close()
        assert(sha.sha256(raw)==req.expected_sha256)
        parts[tonumber(q.partseq)+1]=raw;response.md5=sha.md5(raw)
    elseif q.method=='create' then
        assert(body.path==pending.path and body.rtype=='0')
        local raw=table.concat(parts);assert(#raw==tonumber(body.size))
        stored[body.path]={raw=raw,revision=1};commits=commits+1
        response.path=body.path;response.size=#raw
    elseif q.method=='filemetas' then
        local path=next(stored);local r=stored[path]
        response.list={{path=path,fs_id='123',size=#r.raw,dlink='https://d.pcs.baidu.com/download?access_token=old&sign=x'}}
    elseif endpoint=='/download' then
        assert(q.access_token=='token','dlink must replace stale access_token query values')
        local path=next(stored);local r=stored[path]
        if req.download_path then
            assert(req.reset_download);write(req.download_path,r.raw)
            if changed then r.revision=r.revision+1 end
            return done(nil,{status=200,size=#r.raw,body=''})
        end
        return done(nil,{status=200,body=r.raw})
    else error('unexpected transfer fixture')end
    done(nil,{status=200,body=json.encode(response)})
end
local api=assert(API:new{app_key='app',app_dir=root,user_id='1',access_token='token',expires_at=10000,
    now=function()return 1000 end,transport=transport})
api.operation_opts={schedule=function(cb)cb()end}
local uploads=0
api:upload(target,file,nil,function(e)assert(not e,e and e.message);uploads=uploads+1 end,
    {expected_sha256=plan.sha256,precondition={absent=true}})
assert(uploads==1 and commits==1 and stored[root..'/'..target].raw==data)
api:upload(target,file,nil,function(e)assert(e.code=='CONFLICT')end,{expected_sha256=plan.sha256,precondition={absent=true}})
assert(commits==1,'existing content paths must never be overwritten')
local destination=fixture_temp_dir..'/download.part';write(destination,'')
api:download(target,destination,nil,function(e,r)assert(not e,e and e.message);assert(r.size==#data)end,{max_bytes=#data})
assert(read(destination)==data)
changed=true
api:download(target,destination,nil,function(e)assert(e.code=='CONFLICT')end,{max_bytes=#data})
api:upload(target,file,nil,function(e)assert(e.code=='CONFLICT')end,{expected_sha256=string.rep('0',64)})
print('Baidu multi-slice bounded planning, streamed transfer, source identity and download version regressions passed')
