-- Official API adapter with bounded transfers and optimistic version checks.
-- No atomic conditional write/delete capabilities are advertised.
local A=require('modules/async')
local H=require('modules/baidu_http')
local E=require('modules/errors')
local Identity=require('modules/backend_identity')
local json=require('json')
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
    return setmetatable({root=root,backend_id=id,profile=o,transport=o.transport,
        now=o.now or os.time,kind='baidu',optimistic_versions=true,verify_uploaded_content=true,
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
function M:request(endpoint,method,params,body,writing,headers)
    self:authorized()
    local operation=self.operation_opts
    if operation and operation.guard then A.check(operation.guard()) end
    if operation and operation.is_cancelled and operation.is_cancelled() then fail('CANCELLED','已取消百度任务') end
    params=params or {};params.access_token=self.profile.access_token
    return A.call(function(done)H.request({transport=self.transport,cafile=self.profile.cafile,
        url=endpoint..'?'..H.form(params),method=method,body=body,writing=writing,
        headers=headers or {['User-Agent']='pan.baidu.com',['Content-Type']='application/x-www-form-urlencoded'}},done)end)
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
function M:list(relative,continuation,done)
    A.run(function()
        local dir=self:path(relative)
        local start=continuation or 0
        if type(start)~='number' or start<0 or start%1000~=0 or start>100000 then fail('INVALID_INPUT','百度枚举页码无效') end
        local v=self:request('https://pan.baidu.com/rest/2.0/xpan/file','GET',
            {method='list',dir=dir,start=start,limit=1000,order='name'})
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
function M:stat(relative,done)
    A.run(function()
        local full=self:path(relative)
        if full==self.root then
            A.call(function(cb)self:list('',nil,cb)end)
            return {type='directory',size=0}
        end
        local clean=relative:gsub('/+$','')
        local parent=clean:match('^(.*)/[^/]+$') or ''
        local page
        repeat
            local v=A.call(function(cb)self:list(parent,page,cb)end)
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
function M:check_version(relative,condition)
    if condition and (condition.etag or (not condition.absent and not condition.version)) then
        fail('UNSUPPORTED','百度未提供已验证的原子条件写入')
    end
    local e,current=A.await(function(cb)self:stat(relative,cb)end)
    if e and e.code~='NOT_FOUND' then error(e,0) end
    if condition and condition.version then
        if not current or current.version~=condition.version then fail('CONFLICT','百度远端版本已变化，请重新确认') end
    elseif current then fail('CONFLICT','百度目标已存在，未覆盖文件') end
end
function M:prepare_upload(relative,size,blocks,condition)
    self:check_version(relative,condition)
    local path=self:path(relative)
    local rtype=condition and condition.version and 2 or 0
    if rtype==2 and not relative:match('^progress/[0-9a-f]+%.json$') and not relative:match('^metadata/[0-9a-f]+%.json$') then
        fail('FORBIDDEN','百度只允许更新已确认版本的进度或书籍发布记录')
    end
    local pre=self:request('https://pan.baidu.com/rest/2.0/xpan/file','POST',{method='precreate'},
        H.form{path=path,size=size,isdir=0,autoinit=1,rtype=rtype,block_list=json.encode(blocks)},true)
    if pre.return_type~=1 and pre.return_type~=2 then fail('INVALID_INPUT','百度预创建结果无效') end
    if pre.return_type==1 then
        if type(pre.uploadid)~='string' or pre.uploadid=='' or type(pre.block_list)~='table' then fail('INVALID_INPUT','百度预创建结果无效') end
        local seen={}
        for _,index in ipairs(pre.block_list) do
            if type(index)~='number' or index%1~=0 or index<0 or index>=#blocks or seen[index] then
                fail('INVALID_INPUT','百度返回无效或重复的分片序号')
            end
            seen[index]=true
        end
    end
    return pre,path,rtype
end
function M:commit_upload(relative,size,blocks,condition,pre,path,rtype)
    if pre.return_type~=2 then
        self:check_version(relative,condition)
        local v=self:request('https://pan.baidu.com/rest/2.0/xpan/file','POST',{method='create'},
            H.form{path=path,size=size,isdir=0,uploadid=pre.uploadid,rtype=rtype,block_list=json.encode(blocks)},true)
        if v.path~=path or v.size~=size then fail('UNCERTAIN','百度文件提交结果未确认，请重新查询') end
    end
    local actual=A.call(function(cb)self:stat(relative,cb)end)
    if actual.type~='file' or actual.size~=size then fail('UNCERTAIN','百度文件提交后大小不符') end
    return actual
end
function M:uploadSmallJson(relative,raw,condition,done)
    A.run(function()
        if condition and condition.etag then fail('UNSUPPORTED','百度未提供已验证的原子条件写入') end
        if type(raw)~='string' or #raw>65536 then fail('INVALID_INPUT','JSON 文件不能超过 64 KiB') end
        local ok=pcall(json.decode,raw);if not ok then fail('INVALID_INPUT','文件必须是 JSON') end
        local md5=require('ffi/sha2').md5(raw)
        local blocks={md5}
        local pre,path,rtype=self:prepare_upload(relative,#raw,blocks,condition)
        if pre.return_type==1 and #pre.block_list==1 then
            local boundary='bps-'..A.check(require('modules/random').hex(16))
            local body='--'..boundary..'\r\nContent-Disposition: form-data; name="file"; filename="record.json"\r\n'..
                'Content-Type: application/octet-stream\r\n\r\n'..raw..'\r\n--'..boundary..'--\r\n'
            local slice=self:request('https://d.pcs.baidu.com/rest/2.0/pcs/superfile2','POST',
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
        if opts.precondition and not opts.precondition.absent then fail('UNSUPPORTED','百度 EPUB 仅允许创建新内容路径') end
        local plan=A.call(function(cb)require('modules/baidu_upload_plan').file(file,self.operation_opts or {},cb)end)
        if opts.expected_sha256 and plan.sha256~=opts.expected_sha256 then fail('CONFLICT','上传源文件摘要已变化') end
        local pre,path,rtype=self:prepare_upload(relative,plan.size,plan.blocks,{absent=true})
        if pre.return_type==1 then
            local completed=plan.size
            for _,index in ipairs(pre.block_list) do completed=completed-plan.parts[index+1].size end
            for _,index in ipairs(pre.block_list) do
                local part=plan.parts[index+1]
                local boundary='bps-'..A.check(require('modules/random').hex(16))
                local params={method='upload',type='tmpfile',path=path,uploadid=pre.uploadid,partseq=index,access_token=self.profile.access_token}
                self:authorized()
                local slice=A.call(function(cb)H.request({transport=self.transport,cafile=self.profile.cafile,
                    url='https://d.pcs.baidu.com/rest/2.0/pcs/superfile2?'..H.form(params),method='POST',writing=true,
                    headers={['User-Agent']='pan.baidu.com',['Content-Type']='multipart/form-data; boundary='..boundary},
                    upload_path=file,upload_offset=part.offset,upload_size=part.size,expected_sha256=part.sha256,
                    upload_prefix='--'..boundary..'\r\nContent-Disposition: form-data; name="file"; filename="book.epub"\r\n'..
                        'Content-Type: application/octet-stream\r\n\r\n',upload_suffix='\r\n--'..boundary..'--\r\n',
                    progress_dir=self.progress_dir},cb)end)
                if slice.md5~=plan.blocks[index+1] then fail('CONFLICT','百度 EPUB 分片摘要不一致，未提交文件') end
                completed=completed+part.size
                if progress then progress(completed,plan.size) end
            end
        end
        local st=require('libs/libkoreader-lfs').attributes(file)
        if not st or st.size~=plan.size or st.modification~=plan.mtime then fail('CONFLICT','上传源文件在传输期间发生变化，未提交文件') end
        return self:commit_upload(relative,plan.size,plan.blocks,{absent=true},pre,path,rtype)
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
        local st=A.call(function(cb)self:stat(relative,cb)end)
        if st.type~='file' or st.size>(opts.max_bytes or (destination and 1024*1024*1024 or 65536)) then fail('INVALID_INPUT','百度下载文件大小超出本次限制') end
        local v=self:request('https://pan.baidu.com/rest/2.0/xpan/multimedia','GET',
            {method='filemetas',dlink=1,fsids='['..st.fs_id..']'})
        local item=type(v.list)=='table' and v.list[1]
        if not item or item.path~=self:path(relative) or tostring(item.fs_id)~=st.fs_id or item.size~=st.size
            or type(item.dlink)~='string' then fail('CONFLICT','百度下载元信息与文件不一致') end
        local url=item.dlink
        for _=1,4 do
            if not trusted(url) then fail('TLS','百度未返回受支持的 HTTPS 下载地址，已停止') end
            local e,r=A.await(function(cb)
                (self.transport or require('modules/dav_transport').request)({url=token_url(url,self.profile.access_token),method='GET',cafile=self.profile.cafile,
                    headers={['User-Agent']='pan.baidu.com'},max_bytes=st.size,
                    download_path=destination,reset_download=destination~=nil,progress_dir=destination and self.progress_dir or nil,
                    wait_message='正在从百度网盘下载（点击可取消）…'},cb)
            end)
            if e then error(e,0) end
            if r.status==200 then
                local actual=destination and r.size or (type(r.body)=='string' and #r.body)
                if actual~=st.size then fail('CONFLICT','百度文件下载大小不符') end
                local after=A.call(function(cb)self:stat(relative,cb)end)
                if after.version~=st.version then fail('CONFLICT','百度文件在下载期间发生变化') end
                if progress then progress(st.size,st.size) end
                return destination and {size=st.size} or r.body
            end
            if r.status~=301 and r.status~=302 and r.status~=307 and r.status~=308 then fail('NETWORK','百度下载失败，请重新授权或检查权限') end
            local location=r.headers and (r.headers.location or r.headers.Location)
            if type(location)~='string' then fail('NETWORK','百度下载重定向缺少目标') end
            url=require('socket.url').absolute(url,location)
        end
        fail('NETWORK','百度下载重定向次数过多')
    end,done)
end
function M:delete(relative,condition,done)
    A.run(function()
        if condition then
            if type(condition.version)~='string' or condition.etag or condition.absent then fail('UNSUPPORTED','百度删除需要已确认的文件版本') end
            local id=relative:match('^books/([0-9a-f]+)%.epub$') or relative:match('^metadata/([0-9a-f]+)%.json$')
                or relative:match('^progress/([0-9a-f]+)%.json$')
            if not id or #id~=64 then fail('FORBIDDEN','只允许删除已确认的书籍及关联文件') end
            self:check_version(relative,condition)
        elseif not relative:match('^c2%-probe%-%x+/') then
            fail('FORBIDDEN','删除书籍必须确认目标版本')
        end
        local v=self:request('https://pan.baidu.com/rest/2.0/xpan/file','POST',
            {method='filemanager',opera='delete'},H.form{async=0,filelist=json.encode({self:path(relative)})},true)
        if type(v.info)~='table' or #v.info~=1 or v.info[1].errno~=0 then fail('UNCERTAIN','百度文件删除未确认') end
        local e=A.await(function(cb)self:stat(relative,cb)end)
        if not e or e.code~='NOT_FOUND' then fail('UNCERTAIN','百度文件删除后未确认消失，请刷新核对') end
        return v
    end,done)
end
function M:move(_,_,_,done)return done(E.new('UNSUPPORTED','百度 MOVE 未验证'))end
return M
