local Hash=require('modules/hash')
local Errors=require('modules/errors')
local M={};M.__index=M
local function errorcode(code)return Errors.new(code,code)end
function M:new()
    return setmetatable({files={},dirs={['']=true},root='http://test/sync/',backend_id=Hash.sha256_text('test backend'),
        conditional_verified=true,conditional_delete_verified=true,calls={},writes={}},self)
end
function M:before(method,path)
    self.calls[#self.calls+1]={method=method,path=path}
    if self.hook then return self.hook(method,path,self) end
end
function M:tag(path)return self.files[path] and '"'..Hash.sha256_text(self.files[path])..'"'end
function M:stat(path,cb)
    local e=self:before('stat',path);if e then return cb(e)end
    if self.dirs[path:gsub('/+$','')] then return cb(nil,{type='directory'})end
    if not self.files[path] then return cb(errorcode('NOT_FOUND'))end
    cb(nil,{type='file',size=#self.files[path],etag=self:tag(path),weak_etag=false})
end
function M:mkdir(path,cb)
    self:before('mkdir',path);self.dirs[path:gsub('/+$','')]=true;cb(nil,{})
end
function M:list(path,_,cb)
    local e=self:before('list',path);if e then return cb(e)end
    local prefix=path:gsub('/+$','')..'/'
    local entries={}
    for file,raw in pairs(self.files)do
        if file:sub(1,#prefix)==prefix and not file:sub(#prefix+1):find('/',1,true) then
            entries[#entries+1]={path=file,type='file',size=#raw,etag=self:tag(file)}
        end
    end
    cb(nil,{entries=entries})
end
function M:download(path,destination,progress,cb,opts)
    if type(destination)=='function'then cb=destination;destination=nil end
    local e=self:before('download',path);if e then return cb(e)end
    local raw=self.files[path];if not raw then return cb(errorcode('NOT_FOUND'))end
    if destination then
        local f=assert(io.open(destination,'r+b'));f:write(raw);f:close();cb(nil,{size=#raw})
    else cb(nil,raw)end
end
function M:check(path,pre)
    if pre and ((pre.absent and self.files[path])or(pre.etag and pre.etag~=self:tag(path)))then return errorcode('CONFLICT')end
end
function M:uploadSmallJson(path,raw,pre,cb)
    local e=self:before('put',path)or self:check(path,pre);if e then return cb(e)end
    self.files[path]=raw;self.writes[#self.writes+1]=path;cb(nil,{})
end
function M:upload(path,file,progress,cb,opts)
    local e=self:before('upload',path)or self:check(path,opts.precondition);if e then return cb(e)end
    local f=assert(io.open(file,'rb'));local raw=f:read('*a');f:close()
    if Hash.sha256_text(raw)~=opts.expected_sha256 then return cb(errorcode('CONFLICT'))end
    self.files[path]=raw;self.writes[#self.writes+1]=path;cb(nil,{})
end
function M:delete(path,pre,cb)
    local e=self:before('delete',path)or self:check(path,pre);if e then return cb(e)end
    self.files[path]=nil;cb(nil,{})
end
return M
