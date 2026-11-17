-- Independent TLS socket factory: peer-chain verification plus SAN-only identity.
-- Never uses KOReader's CN-first ssl.checkhostname or verify=none defaults.
local M={}
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
function M.factory(cafile)
    local ssl=require('ssl')
    cafile=cafile or (ssl.get_system_ca and ssl.get_system_ca())
    if type(cafile)~='string' or require('libs/libkoreader-lfs').attributes(cafile,'mode')~='file' then
        return nil,'没有可用的可信 CA 文件'
    end
    local socket=require('socket')
    local state={code='NETWORK'}
    local function create()
        local conn={sock=assert(socket.tcp())}
        function conn:connect(host,port)
            local ok,e=self.sock:connect(host,port)
            if not ok then return nil,e end
            state.code='TLS'
            local secure,wrap_err=ssl.wrap(self.sock,{mode='client',protocol='any',verify='peer',
                cafile=cafile,options={'all','no_sslv2','no_sslv3','no_tlsv1','no_tlsv1_1'}})
            if not secure then self.sock:close();return nil,wrap_err end
            self.sock=secure
            secure:settimeout(5)
            local sni_ok=pcall(function()secure:sni(host)end)
            if not sni_ok then secure:close();return nil,'SNI unavailable' end
            local hand,hand_err=secure:dohandshake()
            if not hand then secure:close();return nil,hand_err end
            local valid,matched=pcall(M.matches,secure:getpeercertificate(),host)
            if not valid or not matched then secure:close();return nil,'SAN identity mismatch' end
            state.code='NETWORK'
            return 1
        end
        return setmetatable(conn,{__index=function(self,key)
            return function(_,...) return self.sock[key](self.sock,...) end
        end})
    end
    return create,nil,state
end
return M
