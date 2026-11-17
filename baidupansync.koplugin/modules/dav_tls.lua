-- Independent TLS socket factory: peer-chain verification plus SAN-only identity.
-- Never uses KOReader's CN-first ssl.checkhostname or verify=none defaults.
local M={}
local lfs=require('libs/libkoreader-lfs')
local source=debug and debug.getinfo and debug.getinfo(1,'S').source or ''
local module_path=source:gsub('^@',''):gsub('\\','/')
local plugin_root=module_path:match('^(.*)/modules/dav_tls%.lua$')
if module_path=='modules/dav_tls.lua' then plugin_root='.' end
local function readable(path)
    if type(path)~='string' or path=='' or path:find('%z') then return false end
    if lfs.attributes(path,'mode')~='file' then return false end
    local f=io.open(path,'rb')
    if not f then return false end
    local first=f:read(1);f:close()
    return first~=nil
end
function M.ca_file(explicit,ssl)
    if explicit~=nil and explicit~='' then
        if readable(explicit) then return explicit end
        return nil,'指定的 CA 文件不存在、为空或不可读，请修正路径或留空自动查找'
    end
    if ssl and type(ssl.get_system_ca)=='function' then
        local ok,path=pcall(ssl.get_system_ca)
        if ok and readable(path) then return path end
    end
    -- KOReader's bundled CA path, plus the legacy Turbo installation path.
    local paths={'data/ca-bundle.crt','common/turbo/ca-certificates.crt'}
    if plugin_root then paths[#paths+1]=plugin_root..'/resources/ca-bundle.crt' end
    for _,path in ipairs({os.getenv('SSL_CERT_FILE') or '',
        '/etc/ssl/certs/ca-certificates.crt','/etc/pki/tls/certs/ca-bundle.crt',
        '/etc/ssl/ca-bundle.pem','/etc/ssl/cert.pem'}) do paths[#paths+1]=path end
    for _,path in ipairs(paths) do if readable(path) then return path end end
    return nil,'没有可用的可信 CA 文件；请完整安装插件 resources/ca-bundle.crt，或在应用配置中填写 CA 文件路径'
end
local function ip_bytes(value)
    local ffi=require('ffi')
    pcall(ffi.cdef,'int inet_pton(int af, const char *src, void *dst);')
    local buf=ffi.new('unsigned char[16]')
    local family=value:find(':',1,true) and (jit.os=='OSX' and 30 or 10) or 2
    local ok,result=pcall(function()return ffi.C.inet_pton(family,value,buf)end)
    if ok and result==1 then return ffi.string(buf,family==2 and 4 or 16) end
end
function M.matches(cert,host)
    if type(host)~='string' or host:find('[%z%c]') then return false end
    host=host:gsub('^%[',''):gsub('%]$',''):lower()
    local extensions=cert:extensions()
    local san=extensions and extensions['2.5.29.17']
    if not san then return false end -- legacy CN-only certificates are unsupported
    local ip=ip_bytes(host)
    if ip then
        for _,value in ipairs(san.iPAddress or {}) do
            if type(value)=='string' and ip_bytes(value)==ip then return true end
        end
        return false
    end
    if host:find('[^%w%.%-]') or host:match('^%d+%.%d+%.%d+%.%d+$') then return false end
    for _,name in ipairs(san.dNSName or {}) do
        if type(name)=='string' and not name:find('[%z%c]') then
            name=name:lower()
            if name==host then return true end
            local suffix=name:match('^%*%.([%w%.%-]+)$')
            -- Wildcard matches exactly one label; disallow top-level wildcards.
            if suffix and suffix:find('.',1,true) then
                local rest=host:match('^[^.]+%.(.+)$')
                if rest==suffix then return true end
            end
        end
    end
    return false
end
function M.factory(cafile,opts)
    opts=opts or {}
    local loaded,ssl=pcall(require,'ssl')
    if not loaded then return nil,'KOReader 缺少可用的 LuaSec TLS 模块，请检查安装' end
    local reason
    cafile,reason=M.ca_file(cafile,ssl)
    if not cafile then return nil,reason end
    local socket=require('socket')
    local state={code='NETWORK'}
    local function create()
        local conn={sock=assert(socket.tcp()),timeouts={}}
        function conn:settimeout(value,mode)
            self.timeouts=self.timeouts or {}
            self.timeouts[mode or 'b']=value
            return self.sock:settimeout(value,mode)
        end
        function conn:connect(host,port)
            state.stage='TCP连接';state.code='NETWORK'
            local ok,e=self.sock:connect(host,port)
            if not ok then return nil,e end
            state.code='TLS'
            state.stage='TLS握手'
            local secure,wrap_err=ssl.wrap(self.sock,{mode='client',protocol='any',verify='peer',
                cafile=cafile,options={'all','no_sslv2','no_sslv3','no_tlsv1','no_tlsv1_1'}})
            if not secure then self.sock:close();return nil,wrap_err end
            self.sock=secure
            secure:settimeout(opts.handshake_timeout or 30)
            local sni_ok=pcall(function()secure:sni(host)end)
            if not sni_ok then secure:close();return nil,'SNI unavailable' end
            local hand,hand_err=secure:dohandshake()
            if not hand then secure:close();return nil,hand_err end
            local valid,matched=pcall(M.matches,secure:getpeercertificate(),host)
            if not valid or not matched then secure:close();return nil,'SAN identity mismatch' end
            -- ssl.wrap creates a new socket timeout context. A handshake-only
            -- limit must not remain active for the entire EPUB download.
            secure:settimeout((self.timeouts and self.timeouts.t) or opts.total_timeout or 120,'t')
            secure:settimeout((self.timeouts and self.timeouts.b) or opts.block_timeout or 15,'b')
            state.code='NETWORK'
            state.stage='收发HTTP数据'
            return 1
        end
        return setmetatable(conn,{__index=function(self,key)
            return function(_,...) return self.sock[key](self.sock,...) end
        end})
    end
    return create,nil,state
end
return M
