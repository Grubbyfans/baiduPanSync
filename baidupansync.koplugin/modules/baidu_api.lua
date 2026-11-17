-- C2 adapter: official APIs, small JSON transfers only. No conditional writes
-- are advertised, and this adapter is not yet connected to book/progress UI.
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
        now=o.now or os.time,conditional_verified=false,conditional_delete_verified=false},self)
end
function M:capabilities()
    return {mkdir=true,delete=true,conditional_create=false,conditional_replace=false,
        conditional_delete=false,move=false,atomic_publish=false,small_json_only=true}
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
function M:ensureAuthorized(done)return self:user_info(done)end
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
                size=item.size,fs_id=item.fs_id,md5=item.md5,etag=nil}
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
function M:uploadSmallJson(relative,raw,condition,done)
    A.run(function()
        if condition then fail('UNSUPPORTED','百度未提供已验证的原子条件写入') end
        if type(raw)~='string' or #raw>65536 then fail('INVALID_INPUT','C2 只允许不超过 64 KiB 的测试 JSON') end
        local ok=pcall(json.decode,raw);if not ok then fail('INVALID_INPUT','测试文件必须是 JSON') end
        local path=self:path(relative)
        local md5=require('ffi/sha2').md5(raw)
        local blocks=json.encode({md5})
        local pre=self:request('https://pan.baidu.com/rest/2.0/xpan/file','POST',{method='precreate'},
            H.form{path=path,size=#raw,isdir=0,autoinit=1,rtype=0,block_list=blocks},true)
        if pre.return_type~=2 then
            if pre.return_type~=1 or type(pre.uploadid)~='string' or type(pre.block_list)~='table'
                or #pre.block_list>1 or (#pre.block_list==1 and pre.block_list[1]~=0) then
                fail('INVALID_INPUT','百度预创建结果无效')
            end
            if #pre.block_list==1 then
                local boundary='bps-'..A.check(require('modules/random').hex(16))
                local body='--'..boundary..'\r\nContent-Disposition: form-data; name="file"; filename="probe.json"\r\n'..
                    'Content-Type: application/octet-stream\r\n\r\n'..raw..'\r\n--'..boundary..'--\r\n'
                local slice=self:request('https://d.pcs.baidu.com/rest/2.0/pcs/superfile2','POST',
                    {method='upload',type='tmpfile',path=path,uploadid=pre.uploadid,partseq=0},body,true,
                    {['User-Agent']='pan.baidu.com',['Content-Type']='multipart/form-data; boundary='..boundary})
                if slice.md5~=md5 then fail('CONFLICT','百度上传分片摘要不一致，未提交文件') end
            end
            local created=self:request('https://pan.baidu.com/rest/2.0/xpan/file','POST',{method='create'},
                H.form{path=path,size=#raw,isdir=0,uploadid=pre.uploadid,rtype=0,block_list=blocks},true)
            if created.path~=path or created.size~=#raw then fail('UNCERTAIN','百度文件提交结果未确认，请重新查询') end
        end
        local actual=A.call(function(cb)self:stat(relative,cb)end)
        if actual.type~='file' or actual.size~=#raw then fail('UNCERTAIN','百度文件提交后大小不符') end
        return actual
    end,done)
end
local function trusted(url)
    local p=require('socket.url').parse(url)
    if not p or p.scheme~='https' or not p.host or p.user or p.password or p.fragment
        or (p.port and tostring(p.port)~='443') then return false end
    local host=p.host:lower()
    return host=='baidu.com' or host:sub(-10)=='.baidu.com'
        or host=='baidupcs.com' or host:sub(-13)=='.baidupcs.com'
        or host=='baidubce.com' or host:sub(-13)=='.baidubce.com'
end
function M:download(relative,done)
    A.run(function()
        local st=A.call(function(cb)self:stat(relative,cb)end)
        if st.type~='file' or st.size>65536 then fail('UNSUPPORTED','C2 仅下载小型测试 JSON') end
        local v=self:request('https://pan.baidu.com/rest/2.0/xpan/multimedia','GET',
            {method='filemetas',dlink=1,fsids='['..st.fs_id..']'})
        local item=type(v.list)=='table' and v.list[1]
        if not item or item.path~=self:path(relative) or tostring(item.fs_id)~=st.fs_id or item.size~=st.size
            or type(item.dlink)~='string' then fail('CONFLICT','百度下载元信息与文件不一致') end
        local url=item.dlink
        for _=1,4 do
            if not trusted(url) then fail('TLS','百度未返回受支持的 HTTPS 下载地址，已停止') end
            local e,r=A.await(function(cb)
                (self.transport or require('modules/dav_transport').request)({url=url..(url:find('?',1,true) and '&' or '?')..
                    'access_token='..H.escape(self.profile.access_token),method='GET',cafile=self.profile.cafile,
                    headers={['User-Agent']='pan.baidu.com'},max_bytes=65536},cb)
            end)
            if e then error(e,0) end
            if r.status==200 then
                if type(r.body)~='string' or #r.body~=st.size then fail('CONFLICT','百度测试文件下载大小不符') end
                return r.body
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
        if condition then fail('UNSUPPORTED','百度未验证条件删除能力') end
        if not relative:match('^c2%-probe%-%x+/') then fail('FORBIDDEN','C2 只允许清理随机测试目录内的文件') end
        local v=self:request('https://pan.baidu.com/rest/2.0/xpan/file','POST',
            {method='filemanager',opera='delete'},H.form{async=0,filelist=json.encode({self:path(relative)})},true)
        if type(v.info)~='table' or #v.info~=1 or v.info[1].errno~=0 then fail('UNCERTAIN','百度测试文件删除未确认') end
        return v
    end,done)
end
function M:upload(_,_,_,done)return done(E.new('UNSUPPORTED','C2 尚未接入整本书上传'))end
function M:move(_,_,_,done)return done(E.new('UNSUPPORTED','百度 MOVE 未验证'))end
return M
