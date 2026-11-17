-- Versioned profile plus private credentials, separated by backend identity.
local json=require('json')
local ffi=require('ffi')
local File=require('modules/file_util')
local Errors=require('modules/errors')
local Identity=require('modules/backend_identity')
local Random=require('modules/random')
pcall(ffi.cdef,'int chmod(const char *path, unsigned int mode);')
local M={};M.__index=M
function M:new(o) return setmetatable({config=o.config,dir=o.dir,file=o.dir..'/credentials.json'},self) end
function M:_credentials()
    local lfs=require('libs/libkoreader-lfs')
    if not lfs.symlinkattributes(self.file) then return {schemaVersion=1,data={}} end
    if lfs.symlinkattributes(self.file,'mode')~='file' then return nil,Errors.new('IO','凭据路径不是普通文件') end
    local raw,e=File.read_file(self.file,65536);if not raw then return nil,e end
    local ok,v=pcall(json.decode,raw)
    if not ok or type(v)~='table' or v.schemaVersion~=1 or type(v.data)~='table' then
        return nil,Errors.new('UNSUPPORTED','凭据文件损坏或版本不支持，已保留原文件')
    end
    return v
end
function M:load()
    local state,e=self.config:_read();if not state then return nil,e end
    local p=state.data.webdav
    if not p then return nil end
    local id,ie=Identity.compute(p);if not id then return nil,ie end
    local credentials,ce=self:_credentials();if not credentials then return nil,ce end
    if type(credentials.data[id])~='string' then return nil,Errors.new('AUTH','WebDAV 凭据缺失或无效') end
    return {root_url=p.root_url,username=p.username,password=credentials.data[id],cafile=p.cafile,type='webdav'}
end
function M:save(profile)
    local id,e=Identity.compute(profile);if not id then return nil,e end
    local credentials,ce=self:_credentials();if not credentials then return nil,ce end
    local state,se=self.config:_read();if not state then return nil,se end
    local ok,me=File.mkdir_p(self.dir);if not ok then return nil,Errors.new('IO',tostring(me)) end
    if ffi.C.chmod(self.dir,448)~=0 then return nil,Errors.new('IO','无法保护凭据目录权限') end
    local token,re=Random.hex(16);if not token then return nil,re end
    local tmp=self.file..'.'..token..'.tmp'
    local f=io.open(tmp,'wb');if not f then return nil,Errors.new('IO','无法创建凭据临时文件') end
    if ffi.C.chmod(tmp,384)~=0 then f:close();os.remove(tmp);return nil,Errors.new('IO','无法保护凭据文件权限') end
    credentials.data[id]=profile.password
    local wrote=f:write(json.encode(credentials))
    if wrote then pcall(require('ffi/util').fsyncOpenedFile,f) end
    local closed=f:close()
    if not wrote or not closed then os.remove(tmp);return nil,Errors.new('IO','凭据写入失败') end
    if not os.rename(tmp,self.file) then os.remove(tmp);return nil,Errors.new('IO','凭据替换失败') end
    state.data.webdav={type='webdav',root_url=profile.root_url,username=profile.username,cafile=profile.cafile}
    if state.data.activeBackendType~='baidu' then state.data.activeBackendId=id end
    return self.config:_write(state)
end
return M
