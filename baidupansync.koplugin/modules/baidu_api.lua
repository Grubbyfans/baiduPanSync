-- Official API adapter: single writer, task-specific upload hosts, cached download links.
-- No atomic conditional write/delete capabilities are advertised.
local A=require('modules/async')
local H=require('modules/baidu_http')
local E=require('modules/errors')
local Identity=require('modules/backend_identity')
local json=require('json')
local link_caches={} -- Memory only: URLs and credentials are never written to disk.
local M={};M.__index=M
local function fail(code,message)error(E.new(code,message,{outcome=code=='UNCERTAIN' and 'uncertain' or 'failed'}),0)end
function M.root(value)
    if type(value)~='string' then return nil end
    local name=value:match('^/apps/([^/]+)/?$')
    if not name or name=='.' or name=='..' or name:find('[\\%c]') then return nil end
    return '/apps/'..name
end
function M:new(o)
    local root=M.root(o.app_dir)
    if not root then return nil,E.new('INVALID_INPUT','应用目录必须是 /apps/实际应用目录，不能含子目录或上级路径') end
    local id
    if o.user_id then id=Identity.compute{type='baidu',app_key=o.app_key,app_dir=root,user_id=o.user_id} end
    local key=id or root
    local slot=link_caches[key]
    if not slot or slot.token~=o.access_token then slot={token=o.access_token,files={}};link_caches[key]=slot end
    local cache=slot.files
    return setmetatable({root=root,backend_id=id,profile=o,transport=o.transport,links=cache,
        now=o.now or os.time,kind='baidu',optimistic_versions=false,verify_uploaded_content=false,
        conditional_verified=false,conditional_delete_verified=false},self)
end
function M:capabilities()
    return {mkdir=true,delete=true,conditional_create=false,conditional_replace=false,
        conditional_delete=false,move=false,atomic_publish=false,small_json_only=false}
end
function M:path(relative)
    if type(relative)~='string' or relative:sub(1,1)=='/' or relative:find('[\\%c]')
        or relative:find('//',1,true) then fail('INVALID_INPUT','百度路径必须在应用目录内') end
    for part in relative:gmatch('[^/]+') do
        if part=='.' or part=='..' then fail('INVALID_INPUT','百度路径不能包含上级目录') end
    end
    return self.root..(relative~='' and '/'..relative:gsub('/+$','') or '')
end
function M:authorized()
    local p=self.profile
    if type(p.access_token)~='string' or p.access_token=='' or type(p.expires_at)~='number'
        or self.now()>=p.expires_at-30 then fail('AUTH','百度授权缺失或已过期，请重新授权') end
end
function M:request(endpoint,method,params,body,writing,headers,diagnostics)
    self:authorized()
    local operation=self.operation_opts
    if operation and operation.guard then A.check(operation.guard()) end
    if operation and operation.is_cancelled and operation.is_cancelled() then fail('CANCELLED','已取消百度任务') end
    params=params or {};params.access_token=self.profile.access_token
    return A.call(function(done)H.request({transport=self.transport,cafile=self.profile.cafile,
        url=endpoint..'?'..H.form(params),method=method,body=body,writing=writing,
        headers=headers or {['User-Agent']='pan.baidu.com',['Content-Type']='application/x-www-form-urlencoded'},
        task_progress=operation and operation.task_progress,diagnostics=diagnostics or operation and operation.diagnostics},done)end)
end
function M:user_info(done)
    A.run(function()
        local v=self:request('https://pan.baidu.com/rest/2.0/xpan/nas','GET',{method='uinfo'})
        if type(v.uk)~='string' or not v.uk:match('^[1-9]%d*$') or #v.uk>24 then
            fail('INVALID_INPUT','百度未返回可信的稳定用户标识')
        end
        return {user_id=v.uk,name=type(v.netdisk_name)=='string' and v.netdisk_name or ''}
    end,done)
end
function M:ensureAuthorized(done)
    A.run(function()
        local info=A.call(function(cb)self:user_info(cb)end)
        if info.user_id~=self.profile.user_id then fail('AUTH','百度账户身份已变化，请重新授权') end
        return info
    end,done)
end
function M:list(relative,continuation,done,diagnostics)
    A.run(function()
        local dir=self:path(relative)
        local start=continuation or 0
        if type(start)~='number' or start<0 or start%1000~=0 or start>100000 then fail('INVALID_INPUT','百度枚举页码无效') end
        local v=self:request('https://pan.baidu.com/rest/2.0/xpan/file','GET',
            {method='list',dir=dir,start=start,limit=1000,order='name'},nil,false,nil,diagnostics)
        if type(v.list)~='table' or #v.list>1000 then fail('INVALID_INPUT','百度枚举结果无效') end
        local entries={}
        for _,item in ipairs(v.list) do
            if type(item.path)~='string' or item.path:sub(1,#dir+1)~=dir..'/'
                or item.path:sub(#dir+2):find('/',1,true) or (item.isdir~=0 and item.isdir~=1)
                or type(item.fs_id)~='string' or not item.fs_id:match('^%d+$')
                or type(item.size)~='number' or item.size<0 then fail('INVALID_INPUT','百度返回了目录外或无效的条目') end
            entries[#entries+1]={path=item.path:sub(#self.root+2),type=item.isdir==1 and 'directory' or 'file',
                size=item.size,fs_id=item.fs_id,md5=item.md5,etag=nil,
                version=json.encode({item.fs_id,item.size,item.server_mtime or 0,item.md5 or ''})}
        end
        return {entries=entries,continuation=#v.list==1000 and start+1000 or nil}
    end,done)
end
function M:stat(relative,done,diagnostics)
    A.run(function()
        local full=self:path(relative)
        if full==self.root then
            A.call(function(cb)self:list('',nil,cb,diagnostics)end)
            return {type='directory',size=0}
        end
        local clean=relative:gsub('/+$','')
        local parent=clean:match('^(.*)/[^/]+$') or ''
        local page
        repeat
            local v=A.call(function(cb)self:list(parent,page,cb,diagnostics)end)
            for _,entry in ipairs(v.entries) do if entry.path==clean then return entry end end
            page=v.continuation
        until not page
        fail('NOT_FOUND','百度应用目录中不存在该条目')
    end,done)
end
function M:mkdir(relative,done)
    A.run(function()
        local path=self:path(relative)
        local v=self:request('https://pan.baidu.com/rest/2.0/xpan/file','POST',{method='create'},
            H.form{path=path,isdir=1,rtype=0},true)
        if v.path~=path then fail('UNCERTAIN','百度目录创建结果未确认，请重新查询') end
        return v
    end,done)
end
-- Single writer: no stat/version round trips around mutations.
function M:invalidate_link(relative)self.links[relative]=nil end
function M:remember(relative,v)
    self:invalidate_link(relative)
    local id=v and v.fs_id and tostring(v.fs_id)
    if id and id:match('^%d+$') then self.links[relative]={fs_id=id,size=v.size} end
end
function M:upload_host(relative,uploadid)
    local v=self:request('https://d.pcs.baidu.com/rest/2.0/pcs/file','GET',
        {method='locateupload',appid=250528,path=self:path(relative),uploadid=uploadid,upload_version='2.0'})
    for _,entry in ipairs(type(v.servers)=='table' and v.servers or {}) do
        local host=type(entry)=='table' and entry.server
        -- Only vendor HTTPS hosts, no userinfo, ports, paths or query strings.
        if type(host)=='string' and host:match('^https://[%w%.%-]+%.pcs%.baidu%.com/?$') then
            return host:gsub('/$','')
        end
    end
    fail('TLS','百度未返回可信的 HTTPS 上传域名')
end
function M:prepare_upload(relative,size,blocks,condition)
    local path=self:path(relative)
    self:invalidate_link(relative) -- Also invalidate on uncertain writes.
    local pre=self:request('https://pan.baidu.com/rest/2.0/xpan/file','POST',{method='precreate'},
        H.form{path=path,size=size,isdir=0,autoinit=1,rtype=3,block_list=json.encode(blocks)},true)
    if type(pre.uploadid)~='string' or pre.uploadid=='' or type(pre.block_list)~='table' then
        fail('INVALID_INPUT','百度预创建结果无效')
    end
    if pre.return_type~=1 and pre.return_type~=2 then fail('INVALID_INPUT','百度预创建状态无效') end
    if pre.return_type==1 and #pre.block_list==0 then pre.block_list={0} end
    local seen={}
    for _,index in ipairs(pre.block_list) do
        if type(index)~='number' or index%1~=0 or index<0 or index>=#blocks or seen[index] then
            fail('INVALID_INPUT','百度返回无效或重复的分片序号')
        end
        seen[index]=true
    end
    return pre,path,3
end
function M:commit_upload(relative,size,blocks,condition,pre,path,rtype)
    local v=self:request('https://pan.baidu.com/rest/2.0/xpan/file','POST',{method='create'},
        H.form{path=path,size=size,isdir=0,uploadid=pre.uploadid,rtype=3,block_list=json.encode(blocks)},true)
    if v.path~=path or v.size~=size then fail('UNCERTAIN','百度文件提交结果不符，请重新查询') end
    self:remember(relative,v)
    return v
end
function M:uploadSmallJson(relative,raw,condition,done)
    A.run(function()
        local max=relative=='library.json' and 4*1024*1024 or 65536
        if type(raw)~='string' or #raw>max then fail('INVALID_INPUT','JSON 文件超过大小限制') end
        if not pcall(json.decode,raw) then fail('INVALID_INPUT','文件必须是 JSON') end
        local md5=require('ffi/sha2').md5(raw)
        local blocks={md5}
        local pre,path,rtype=self:prepare_upload(relative,#raw,blocks,condition)
        if pre.return_type==1 then
            local host=self:upload_host(relative,pre.uploadid)
            local boundary='bps-'..A.check(require('modules/random').hex(16))
            local body='--'..boundary..'\r\nContent-Disposition: form-data; name="file"; filename="record.json"\r\n'..
                'Content-Type: application/octet-stream\r\n\r\n'..raw..'\r\n--'..boundary..'--\r\n'
            local slice=self:request(host..'/rest/2.0/pcs/superfile2','POST',
                {method='upload',type='tmpfile',path=path,uploadid=pre.uploadid,partseq=0},body,true,
                {['User-Agent']='pan.baidu.com',['Content-Type']='multipart/form-data; boundary='..boundary})
            if slice.md5~=md5 then fail('CONFLICT','百度上传分片摘要不一致，未提交文件') end
        end
        return self:commit_upload(relative,#raw,blocks,condition,pre,path,rtype)
    end,done)
end
function M:upload(relative,file,progress,done,opts)
    opts=opts or {}
    A.run(function()
        local plan=A.call(function(cb)require('modules/baidu_upload_plan').file(file,self.operation_opts or {},cb)end)
        local pre,path,rtype=self:prepare_upload(relative,plan.size,plan.blocks)
        if pre.return_type==1 then
            local host=self:upload_host(relative,pre.uploadid)
            local completed=plan.size
            for _,index in ipairs(pre.block_list) do completed=completed-plan.parts[index+1].size end
            for _,index in ipairs(pre.block_list) do
                local part=plan.parts[index+1]
                local boundary='bps-'..A.check(require('modules/random').hex(16))
                local params={method='upload',type='tmpfile',path=path,uploadid=pre.uploadid,partseq=index}
                self:authorized();params.access_token=self.profile.access_token
                local slice=A.call(function(cb)H.request({transport=self.transport,cafile=self.profile.cafile,
                    url=host..'/rest/2.0/pcs/superfile2?'..H.form(params),method='POST',writing=true,
                    headers={['User-Agent']='pan.baidu.com',['Content-Type']='multipart/form-data; boundary='..boundary},
                    upload_path=file,upload_offset=part.offset,upload_size=part.size,
                    upload_prefix='--'..boundary..'\r\nContent-Disposition: form-data; name="file"; filename="book.epub"\r\n'..
                        'Content-Type: application/octet-stream\r\n\r\n',upload_suffix='\r\n--'..boundary..'--\r\n',
                    progress_dir=self.progress_dir,task_progress=self.operation_opts and self.operation_opts.task_progress,
                    task_transfer_offset=completed,task_transfer_total=plan.size,
                    diagnostics=self.operation_opts and self.operation_opts.diagnostics},cb)end)
                if slice.md5~=plan.blocks[index+1] then fail('CONFLICT','百度 EPUB 分片摘要不一致，未提交文件') end
                completed=completed+part.size
                if progress then progress(completed,plan.size) end
            end
        end
        local st=require('libs/libkoreader-lfs').attributes(file)
        if not st or st.size~=plan.size or st.modification~=plan.mtime then fail('CONFLICT','上传源文件在传输期间发生变化，未提交文件') end
        return self:commit_upload(relative,plan.size,plan.blocks,nil,pre,path,rtype)
    end,done)
end
local function trusted(url)
    if url:find('[%c%s]') or url:find('\\',1,true) then return false end
    local p=require('socket.url').parse(url)
    if not p or p.scheme~='https' or not p.host or p.user or p.password or p.fragment
        or (p.port and tostring(p.port)~='443') then return false end
    local host=p.host:lower()
    return host=='baidu.com' or host:sub(-10)=='.baidu.com'
        or host=='baidupcs.com' or host:sub(-13)=='.baidupcs.com'
        or host=='baidubce.com' or host:sub(-13)=='.baidubce.com'
end
local function token_url(url,token)
    local base,query=url:match('^(.-)%?(.*)$')
    base=base or url
    local parts={}
    for field in (query or ''):gmatch('[^&]+') do
        local key=field:match('^([^=]+)') or ''
        key=key:gsub('%%(%x%x)',function(h)return string.char(tonumber(h,16))end)
        if key~='access_token' then parts[#parts+1]=field end
    end
    parts[#parts+1]='access_token='..H.escape(token)
    return base..'?'..table.concat(parts,'&')
end
function M:download(relative,destination,progress,done,opts)
    if type(destination)=='function' then done=destination;destination=nil end
    opts=opts or {}
    A.run(function()
        self:authorized()
        local max=opts.max_bytes or (destination and 1024*1024*1024 or relative=='library.json' and 4*1024*1024 or 65536)
        local diagnostic=opts.diagnostics or self.operation_opts and self.operation_opts.diagnostics
        local cached=self.links[relative]
        for attempt=1,2 do
            local link=cached
            if diagnostic then diagnostic:cache('download_link',link and link.dlink and self.now()<(link.expires_at or 0))end
            if not link or not link.dlink or self.now()>=(link.expires_at or 0) then
                local st
                if link and link.fs_id then st=link
                else st=A.call(function(cb)self:stat(relative,cb,diagnostic)end) end
                local endpoint='https://pan.baidu.com/rest/2.0/xpan/multimedia'
                local e,v=A.await(function(cb)A.run(function()
                    return self:request(endpoint,'GET',{method='filemetas',dlink=1,fsids='['..st.fs_id..']'},nil,false,nil,diagnostic)
                end,cb)end)
                if e and e.code=='NOT_FOUND' and link and link.fs_id then
                    -- A same-path replacement can get a new file ID.
                    self:invalidate_link(relative)
                    st=A.call(function(cb)self:stat(relative,cb,diagnostic)end)
                    v=self:request(endpoint,'GET',{method='filemetas',dlink=1,fsids='['..st.fs_id..']'},nil,false,nil,diagnostic)
                elseif e then error(e,0) end
                local item=type(v.list)=='table' and v.list[1]
                if not item or item.path~=self:path(relative) or tostring(item.fs_id)~=st.fs_id
                    or type(item.size)~='number' or item.size<0 or item.size>max or not trusted(item.dlink or '') then
                    self:invalidate_link(relative)
                    fail('INVALID_INPUT','百度下载元信息无效或大小超限')
                end
                link={fs_id=st.fs_id,size=item.size,dlink=item.dlink,expires_at=self.now()+7*3600}
                self.links[relative]=link
            end
            if link.size>max then fail('INVALID_INPUT','百度下载文件超出大小限制') end
            local url=link.dlink
            local stale=false
            for redirect=1,4 do
                if not trusted(url) then fail('TLS','百度下载地址不是可信 HTTPS 地址') end
                local e,r=A.await(function(cb)
                    require('modules/diagnostics').observe(diagnostic,self.transport or require('modules/dav_transport').request,{url=token_url(url,self.profile.access_token),method='GET',cafile=self.profile.cafile,
                        headers={['User-Agent']='pan.baidu.com'},max_bytes=max,download_path=destination,
                        reset_download=destination~=nil,progress_dir=destination and self.progress_dir or nil,
                        task_progress=self.operation_opts and self.operation_opts.task_progress,
                        progress_title=opts.progress_title,wait_message=opts.wait_message or '正在从百度网盘下载（点击可取消）…'},cb)
                end)
                if e then error(e,0) end
                if type(r)~='table' then fail('NETWORK','百度下载未收到有效结果') end
                if r.status==200 then
                    local actual=destination and r.size or (type(r.body)=='string' and #r.body)
                    if actual==link.size then
                        if progress then progress(actual,link.size) end
                        return destination and {size=actual} or r.body
                    end
                    stale=true;break
                elseif r.status==401 or r.status==403 or r.status==404 or r.status==410 then stale=true;break
                elseif r.status==301 or r.status==302 or r.status==307 or r.status==308 then
                    local location=r.headers and (r.headers.location or r.headers.Location)
                    if type(location)~='string' then fail('NETWORK','百度下载重定向缺少目标') end
                    url=require('socket.url').absolute(url,location)
                else fail('NETWORK','百度下载失败：HTTP '..tostring(r.status)) end
            end
            self:invalidate_link(relative);cached=nil
            if not stale then fail('NETWORK','百度下载重定向次数过多') end
        end
        fail('NETWORK','下载链接刷新后仍然无效，请检查授权或文件是否存在')
    end,done)
end
function M:delete(relative,condition,done)
    A.run(function()
        local id=relative:match('^books/(.+)%.[Ee][Pp][Uu][Bb]$') or relative:match('^progress/(.+)%.json$') or relative:match('^covers/(.+)%.json$')
        if not require('modules/book_name').valid(id) and not relative:match('^c2%-probe%-[%w%-]+/probe%.json$') then
            fail('FORBIDDEN','百度删除路径无效')
        end
        self:invalidate_link(relative)
        local v=self:request('https://pan.baidu.com/rest/2.0/xpan/file','POST',
            {method='filemanager',opera='delete'},H.form{async=0,filelist=json.encode({self:path(relative)})},true)
        if type(v.info)=='table' and #v.info==1 and v.info[1].path==self:path(relative) and v.info[1].errno==-9 then return {already_absent=true}end
        if type(v.info)~='table' or #v.info~=1 or v.info[1].path~=self:path(relative) or v.info[1].errno~=0 then
            fail('UNCERTAIN','百度删除结果未确认')
        end
        return v
    end,done)
end
function M:move(_,_,_,done)return done(E.new('UNSUPPORTED','不支持移动文件'))end
return M
