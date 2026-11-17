-- WebDAV adapter. Callbacks are (error, value); transport never redirects.
local Errors = require('modules/errors')
local Identity = require('modules/backend_identity')
local XML = require('modules/dav_xml')
local M = {}; M.__index = M
local function err(code, message, uncertain)
    return Errors.new(code, message, { outcome=uncertain and 'uncertain' or 'failed' })
end
local function safe(path)
    if type(path) ~= 'string' or path:find('[%%\\%c?#]') or path:sub(1,1)=='/' then return false end
    for part in path:gmatch('[^/]+') do if part=='.' or part=='..' then return false end end
    return not path:find('//',1,true)
end
local function encode(s) return (s:gsub('[^%w%-._~/]',function(c) return string.format('%%%02X',c:byte()) end)) end
function M:new(o)
    local root,e = Identity.normalize_webdav(o.root_url); if not root then return nil,e end
    local id,ie = Identity.compute{type='webdav',root_url=root,username=o.username}; if not id then return nil,ie end
    if type(o.password)~='string' or o.password:find('%c') or o.username:find(':',1,true) then
        return nil,err('INVALID_INPUT','WebDAV 凭据格式无效')
    end
    return setmetatable({root=root,backend_id=id,username=o.username,password=o.password,
        transport=o.transport or require('modules/dav_transport').request,
        conditional_delete_verified=o.conditional_delete_verified==true,cafile=o.cafile,conditional_verified=o.conditional_verified==true},self)
end
function M:capabilities()
    return {mkdir=true,delete=true,conditional_create=self.conditional_verified,
        conditional_replace=self.conditional_verified,conditional_delete=self.conditional_delete_verified,move=false,atomic_publish=false}
end
function M:_request(method,path,body,headers,done,transfer)
    if not safe(path) then return done(err('INVALID_INPUT','路径必须位于同步根目录内')) end
    local writing = method=='PUT' or method=='DELETE' or method=='MKCOL'
    local request={url=self.root..encode(path),method=method,body=body,headers=headers or {},
        username=self.username,password=self.password,cafile=self.cafile,progress_dir=self.progress_dir}
    for k,v in pairs(transfer or {}) do request[k]=v end
    return self.transport(request,function(e,r)
        if e then return done(e) end
        if not r or type(r.status)~='number' then return done(err(writing and 'UNCERTAIN' or 'NETWORK','无有效响应',writing)) end
        local code=r.status
        if code>=200 and code<300 then return done(nil,r) end
        local mapped = ({[401]='AUTH',[403]='FORBIDDEN',[404]='NOT_FOUND',[409]='CONFLICT',[412]='CONFLICT',
            [405]='UNSUPPORTED',[507]='IO'})[code] or 'NETWORK'
        return done(err(mapped,'WebDAV HTTP '..code..(code>=300 and code<400 and '：请配置最终根地址，禁止重定向' or ''),writing and code>=500))
    end)
end
function M:ensureAuthorized(done) return self:stat('',done) end
function M:stat(path,done)
    local body='<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getetag/><d:getlastmodified/></d:prop></d:propfind>'
    return self:_request('PROPFIND',path,body,{Depth='0',['Content-Type']='application/xml'},function(e,r)
        if e then return done(e) end
        local root=XML.parse(r.body)
        if r.status~=207 or not root or root.namespace~='DAV:' or root.name~='multistatus' then
            return done(err('INVALID_INPUT','无效的 DAV stat 响应'))
        end
        local expected=require('socket.url').parse(self.root..encode(path))
        local function decode(v)return (v:gsub('%%(%x%x)',function(h)return string.char(tonumber(h,16))end))end
        for _,response in ipairs(root.children) do
            if response.namespace=='DAV:' and response.name=='response' then
                local href=XML.child(response,'href')
                local uri=href and require('socket.url').parse(href.text)
                if not uri or uri.query or uri.fragment or uri.user or uri.password
                    or (uri.host and (uri.host~=expected.host or uri.scheme~=expected.scheme
                        or tostring(uri.port or '')~=tostring(expected.port or '')))
                    or decode(uri.path or ''):gsub('/+$','')~=decode(expected.path):gsub('/+$','') then
                    return done(err('FORBIDDEN','DAV stat 返回了不同目标'))
                end
                for _,ps in ipairs(response.children) do
                    local status=ps.namespace=='DAV:' and ps.name=='propstat' and XML.child(ps,'status')
                    local prop=status and XML.child(ps,'prop')
                    if status and status.text:match('HTTP/%d%.%d 200') and prop then
                        local rt=XML.child(prop,'resourcetype')
                        if not rt then return done(err('INVALID_INPUT','DAV stat 缺少资源类型')) end
                        local size=XML.child(prop,'getcontentlength');local etag=XML.child(prop,'getetag')
                        local modified=XML.child(prop,'getlastmodified')
                        local tag=etag and etag.text
                        return done(nil,{type=XML.child(rt,'collection') and 'directory' or 'file',
                            size=size and tonumber(size.text),etag=tag,weak_etag=tag and tag:match('^W/')~=nil,
                            modified=modified and modified.text})
                    end
                end
                return done(err('FORBIDDEN','DAV stat 属性不可读'))
            end
        end
        return done(err('INVALID_INPUT','DAV stat 响应缺少目标'))
    end)
end

function M:mkdir(path,done) return self:_request('MKCOL',path,nil,nil,done) end
function M:_condition(pre)
    if not pre then return {} end
    if not self.conditional_verified then return nil,err('UNSUPPORTED','服务器条件写入尚未验证') end
    if pre.absent==true and pre.etag==nil then return {['If-None-Match']='*'} end
    if pre.absent==nil and type(pre.etag)=='string' and pre.etag:match('^"[^"%c]+"$') then
        return {['If-Match']=pre.etag}
    end
    return nil,err('INVALID_INPUT','需要不存在条件或强 ETag；弱 ETag 不能用于 If-Match')
end
function M:uploadSmallJson(path,text,pre,done)
    if type(text)~='string' or #text>65536 then return done(err('INVALID_INPUT','测试 JSON 超过 64 KiB')) end
    local h,e=self:_condition(pre); if not h then return done(e) end
    h['Content-Type']='application/json'
    return self:_request('PUT',path,text,h,done)
end
function M:delete(path,pre,done)
    -- Only probe files and explicitly versioned book-owned files are allowed.
    local publication=type(path)=='string' and (path:match('^metadata/([0-9a-f]+)%.json$')
        or path:match('^progress/([0-9a-f]+)%.json$') or path:match('^books/([0-9a-f]+)%.epub$'))
    if not (type(path)=='string' and path:match('^%.baidupansync%-probe%-%x+/[^/]+$'))
        and not (publication and #publication==64 and pre and pre.etag) then
        return done(err('FORBIDDEN','仅允许清理探测文件或按强版本删除指定书籍文件'))
    end
    if publication and not self.conditional_delete_verified then return done(err('UNSUPPORTED','条件删除尚未验证，拒绝删除书籍文件')) end
    local h,e=self:_condition(pre); if not h then return done(e) end
    return self:_request('DELETE',path,nil,h,done)
end
-- Small JSON stays bounded in memory; EPUB streams to a task-owned file.
function M:download(path,destination,progress,done,opts)
    if type(destination)=='function' then done=destination;destination=nil end
    done=done or function() end
    if not destination then
        return self:_request('GET',path,nil,nil,function(e,r) done(e,r and r.body) end)
    end
    local attr=require('libs/libkoreader-lfs').symlinkattributes(destination)
    if type(destination)~='string' or destination:sub(-5)~='.part' or not attr or attr.mode~='file' or attr.size~=0 then
        return done(err('INVALID_INPUT','下载必须使用本任务预留的空 .part 临时文件'))
    end
    return self:_request('GET',path,nil,nil,function(e,r)
        if not e and progress then pcall(progress,r.size,r.size) end
        done(e,r)
    end,{download_path=destination,max_bytes=opts and opts.max_bytes or 1024*1024*1024,
        progress_title=opts and opts.progress_title,wait_message=opts and opts.wait_message})
end
function M:upload(path,local_file,progress,done,opts)
    opts=opts or {}
    local attr=require('libs/libkoreader-lfs').attributes(local_file)
    if not attr or attr.mode~='file' then return done(err('IO','上传源文件不可读')) end
    local h,e=self:_condition(opts.precondition);if not h then return done(e) end
    h['Content-Type']='application/epub+zip'
    return self:_request('PUT',path,nil,h,function(upload_err,r)
        if not upload_err and progress then pcall(progress,attr.size,attr.size) end
        done(upload_err,r)
    end,{upload_path=local_file,upload_size=attr.size,expected_sha256=opts.expected_sha256})
end
function M:move(_,_,_,done) return done(err('UNSUPPORTED','此服务未验证 MOVE 能力')) end
function M:list(path,continuation,done)
    if continuation then return done(err('UNSUPPORTED','此 WebDAV 枚举不支持续页')) end
    local body='<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getetag/></d:prop></d:propfind>'
    return self:_request('PROPFIND',path,body,{Depth='1',['Content-Type']='application/xml'},function(e,r)
        if e then return done(e) end
        local root=XML.parse(r.body)
        if r.status~=207 or not root or root.name~='multistatus' or root.namespace~='DAV:' then return done(err('INVALID_INPUT','无效的 DAV 多状态响应')) end
        local entries={}
        local base=require('socket.url').parse(self.root).path
        for _,response in ipairs(root.children) do
            if response.name=='response' and response.namespace=='DAV:' then
                local href=XML.child(response,'href'); if not href then return done(err('INVALID_INPUT','DAV 条目缺少 href')) end
                local uri=require('socket.url').parse(href.text)
                if not uri or uri.query or uri.fragment or uri.user or uri.password then
                    return done(err('FORBIDDEN','DAV href 包含不允许的 URL 字段'))
                end
                if uri.host and (not uri.scheme or (uri.scheme..'://'..uri.authority..'/') ~= self.root:match('^(https?://[^/]+/)')) then
                    return done(err('FORBIDDEN','DAV 条目越出主机'))
                end
                local raw=uri.path or ''
                if raw:find('%%2[fF]') or raw:find('%%5[cC]') then return done(err('FORBIDDEN','DAV 路径包含编码分隔符')) end
                raw=raw:gsub('%%(%x%x)',function(h)return string.char(tonumber(h,16))end)
                local decoded_base=base:gsub('%%(%x%x)',function(h)return string.char(tonumber(h,16))end)
                if raw:sub(1,#decoded_base)~=decoded_base then return done(err('FORBIDDEN','DAV 条目越出根目录')) end
                local rel=raw:sub(#decoded_base+1)
                if not safe(rel) then return done(err('FORBIDDEN','DAV 条目路径无效')) end
                local prefix=path=='' and '' or path:gsub('/+$','')..'/'
                if rel~=path and rel~=prefix then
                    if rel:sub(1,#prefix)~=prefix or rel:sub(#prefix+1):gsub('/$',''):find('/',1,true) then
                        return done(err('FORBIDDEN','DAV 返回非直接子项'))
                    end
                    local found
                    for _,ps in ipairs(response.children) do
                        if ps.name=='propstat' and ps.namespace=='DAV:' then
                            local status=XML.child(ps,'status');local prop=XML.child(ps,'prop')
                            if status and status.text:match('HTTP/%d%.%d 200') and prop then
                                local size=XML.child(prop,'getcontentlength');local etag=XML.child(prop,'getetag')
                                local rt=XML.child(prop,'resourcetype')
                                found={path=rel,size=size and tonumber(size.text),etag=etag and etag.text,
                                    type=rt and XML.child(rt,'collection') and 'directory' or 'file'}
                            end
                        end
                    end
                    if not found then return done(err('FORBIDDEN','DAV 条目属性读取失败，枚举不完整')) end
                    entries[#entries+1]=found
                end
            end
        end
        done(nil,{entries=entries})
    end)
end
return M
