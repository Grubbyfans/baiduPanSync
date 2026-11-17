-- One atomic private record: app credentials and verified account tokens.
-- Kept separate from WebDAV credentials/config, with no implicit backend switch.
local File=require('modules/file_util')
local Errors=require('modules/errors')
local Identity=require('modules/backend_identity')
local Random=require('modules/random')
local json=require('json')
local lfs=require('libs/libkoreader-lfs')
local ffi=require('ffi')
pcall(ffi.cdef,'int chmod(const char *path, unsigned int mode);')
local M={};M.__index=M
function M:new(o)return setmetatable({dir=o.dir,file=o.dir..'/baidu_credentials.json'},self)end
function M.valid(p)
    if not (type(p)=='table' and type(p.app_key)=='string' and #p.app_key>0 and #p.app_key<=256
        and not p.app_key:find('[^%w_%-]') and type(p.secret_key)=='string' and #p.secret_key>0
        and #p.secret_key<=512 and not p.secret_key:find('%c') and require('modules/baidu_api').root(p.app_dir)
        and (not p.cafile or type(p.cafile)=='string')) then return false end
    if p.access_token~=nil then
        if type(p.access_token)~='string' or #p.access_token<1 or #p.access_token>4096 or p.access_token:find('%c')
            or type(p.user_id)~='string' or not p.user_id:match('^[1-9]%d*$') or #p.user_id>24
            or type(p.expires_at)~='number' or p.expires_at~=p.expires_at or p.expires_at<=0
            or p.expires_at>=math.huge or type(p.obtained_at)~='number' or p.obtained_at>=p.expires_at
            or type(p.account_name)~='string' or #p.account_name>512 then return false end
    end
    return true
end
function M:load()
    if not lfs.symlinkattributes(self.file) then return nil end
    if lfs.symlinkattributes(self.file,'mode')~='file' then return nil,Errors.new('IO','百度凭据路径不是普通文件') end
    local raw,e=File.read_file(self.file,32768);if not raw then return nil,e end
    local ok,v=pcall(json.decode,raw)
    if not ok or type(v)~='table' or v.schemaVersion~=1 or not M.valid(v.data) then
        return nil,Errors.new('UNSUPPORTED','百度配置损坏或版本不支持，已保留原文件')
    end
    return v.data
end
function M:save(p)
    if not M.valid(p) then return nil,Errors.new('INVALID_INPUT','请填写有效的 AppKey、SecretKey 和 /apps/实际应用目录') end
    local old,e=self:load();if e then return nil,e end
    local ok=File.mkdir_p(self.dir)
    if not ok or ffi.C.chmod(self.dir,448)~=0 then return nil,Errors.new('IO','无法保护百度凭据目录') end
    local token,re=Random.hex(16);if not token then return nil,re end
    local tmp=self.file..'.'..token..'.tmp'
    local f=io.open(tmp,'wb');if not f then return nil,Errors.new('IO','无法创建百度凭据文件') end
    if ffi.C.chmod(tmp,384)~=0 then f:close();os.remove(tmp);return nil,Errors.new('IO','无法保护百度凭据权限') end
    local wrote=f:write(json.encode{schemaVersion=1,data=p})
    if wrote then pcall(require('ffi/util').fsyncOpenedFile,f) end
    local closed=f:close()
    if not wrote or not closed or not os.rename(tmp,self.file) then
        os.remove(tmp);return nil,Errors.new('IO','百度凭据保存失败，原有凭据保留')
    end
    return true
end
return M
