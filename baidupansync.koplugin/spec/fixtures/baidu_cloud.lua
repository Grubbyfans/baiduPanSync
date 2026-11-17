-- In-memory official HTTP API fixture; production orchestration/adapter are used.
local API=require('modules/baidu_api')
local Form=require('modules/baidu_auth_server').form
local json=require('json')
local sha=require('ffi/sha2')
local M={}
function M.new(root,user)
    local remote={files={},dirs={[root]=true},sequence=0,uploads=0}
    local function respond(done,value)done(nil,{status=200,body=json.encode(value)})end
    remote.put=function(path,raw)
        remote.sequence=remote.sequence+1
        local old=remote.files[path]
        remote.files[path]={raw=raw,id=old and old.id or tostring(remote.sequence),revision=remote.sequence}
    end
    remote.transport=function(req,done)
        local endpoint,query=req.url:match('^https://[^/]+([^?]+)%?(.*)$')
        local q=assert(Form(query));local body=req.body and Form(req.body) or {}
        local response={errno=0}
        if q.method=='uinfo' then response.uk=user;response.netdisk_name='测试用户'
        elseif q.method=='list' then
            if not remote.dirs[q.dir] then return respond(done,{errno=-9})end
            local list={}
            for path in pairs(remote.dirs)do
                if path:match('^(.*)/[^/]+$')==q.dir then
                    list[#list+1]={path=path,fs_id='1000',size=0,isdir=1}
                end
            end
            for path,r in pairs(remote.files)do
                if path:match('^(.*)/[^/]+$')==q.dir then
                    list[#list+1]={path=path,fs_id=r.id,size=#r.raw,isdir=0,server_mtime=r.revision,md5=sha.md5(r.raw)}
                end
            end
            table.sort(list,function(a,b)return a.path<b.path end)
            response.list={}
            for i=tonumber(q.start)+1,math.min(#list,tonumber(q.start)+tonumber(q.limit))do response.list[#response.list+1]=list[i]end
        elseif q.method=='create' and body.isdir=='1' then
            remote.dirs[body.path]=true;response.path=body.path
        elseif q.method=='precreate' then
            remote.pending=body;remote.parts={};response.return_type=1;response.uploadid='fixture-upload';response.block_list={}
            for i in ipairs(json.decode(body.block_list))do response.block_list[#response.block_list+1]=i-1 end
            if remote.after_precreate then remote.after_precreate(body.path)end
        elseif q.method=='upload' then
            local raw
            if req.upload_path then
                local f=assert(io.open(req.upload_path,'rb'));f:seek('set',req.upload_offset);raw=f:read(req.upload_size);f:close()
                assert(sha.sha256(raw)==req.expected_sha256)
            else raw=req.body:match('\r\n\r\n(.-)\r\n%-%-bps%-')end
            remote.parts[tonumber(q.partseq)+1]=raw;response.md5=sha.md5(raw)
        elseif q.method=='create' then
            if body.rtype=='0' and remote.files[body.path] then return respond(done,{errno=-8})end
            assert(body.path==remote.pending.path)
            local raw=table.concat(remote.parts);assert(#raw==tonumber(body.size))
            remote.put(body.path,raw);remote.uploads=remote.uploads+1
            response.path=body.path;response.size=#raw
            if remote.after_create then remote.after_create(body.path,raw)end
        elseif q.method=='filemanager' then
            assert(q.opera=='delete' and body.async=='0')
            local paths=json.decode(body.filelist);assert(#paths==1)
            if remote.before_delete then remote.before_delete(paths[1])end
            remote.files[paths[1]]=nil
            response.info={{path=paths[1],errno=0}}
        elseif q.method=='filemetas' then
            local id=tostring(json.decode(q.fsids)[1]);local path,record
            for p,r in pairs(remote.files)do if r.id==id then path=p;record=r end end
            assert(record)
            response.list={{path=path,fs_id=id,size=#record.raw,dlink='https://d.pcs.baidu.com/download?fixture_id='..id}}
        elseif endpoint=='/download' then
            local raw
            for _,r in pairs(remote.files)do if r.id==q.fixture_id then raw=r.raw end end
            assert(raw)
            if req.download_path then
                assert(req.reset_download)
                local f=assert(io.open(req.download_path,'wb'));f:write(raw);f:close()
                return done(nil,{status=200,body='',size=#raw})
            end
            return done(nil,{status=200,body=raw,size=#raw})
        else error('unsupported Baidu cloud fixture operation')end
        respond(done,response)
    end
    remote.api=function()
        return assert(API:new{app_dir=root,app_key='fixture-app',user_id=user,access_token='token',expires_at=os.time()+3600,
            transport=remote.transport})
    end
    return remote
end
return M
