-- Nonblocking, bounded HTTP receiver on one private IPv4 interface.
local E=require('modules/errors')
local Random=require('modules/random')
local Page=require('modules/baidu_auth_page')
local M={};M.__index=M
function M.private_ip(ip)
    if type(ip)~='string' then return false end
    local a,b,c,d=ip:match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$')
    a,b,c,d=tonumber(a),tonumber(b),tonumber(c),tonumber(d)
    return a and b and c and d and a<=255 and b<=255 and c<=255 and d<=254 and d>0
        and (a==10 or (a==172 and b>=16 and b<=31) or (a==192 and b==168)) or false
end
function M.detect_ip()
    local s=require('socket').udp()
    if not s then return nil end
    s:settimeout(0)
    -- UDP connect only selects the outgoing interface; no datagram is sent.
    local ok=s:setpeername('1.1.1.1',53)
    local ip=ok and s:getsockname();s:close()
    return M.private_ip(ip) and ip or nil
end
local function unform(s)
    if s:gsub('%%%x%x',''):find('%',1,true) then return nil end
    return (s:gsub('+',' '):gsub('%%(%x%x)',function(h)return string.char(tonumber(h,16))end))
end
function M.form(body)
    local values={}
    for field in body:gmatch('[^&]+') do
        local k,v=field:match('^([^=]+)=(.*)$')
        k=k and unform(k);v=v and unform(v)
        if not k or not v or values[k] then return nil end
        values[k]=v
    end
    return values
end
function M.start(o)
    local ip=o.ip or M.detect_ip()
    if not M.private_ip(ip) then return nil,E.new('NETWORK','未找到局域网 IPv4 地址，请连接 Wi-Fi 或手动填写阅读器 IP') end
    local random=o.random or Random.hex
    local token,e=random(24);if not token then return nil,e end
    local csrf,ce=random(16);if not csrf then return nil,ce end
    local state,se=random(16);if not state then return nil,se end
    local socket=o.socket or require('socket')
    local listener=socket.tcp()
    if not listener then return nil,E.new('IO','无法创建临时授权服务') end
    listener:settimeout(0)
    if not listener:bind(ip,0) or not listener:listen(4) then
        listener:close();return nil,E.new('NETWORK','无法监听阅读器 IP，请检查 Wi-Fi 地址或设备防火墙')
    end
    local _,port=listener:getsockname()
    local now=o.now or socket.gettime
    local self=setmetatable({listener=listener,clients={},ip=ip,authority=ip..':'..port,
        path='/authorize/'..token,csrf=csrf,oauth_state=state,now=now,deadline=now()+600,
        on_code=o.on_code,on_stop=o.on_stop,on_tick=o.on_tick,schedule=o.schedule,unschedule=o.unschedule,
        state='waiting',message='等待手机提交授权码',ip_check=o.ip_check},M)
    if not self.ip_check and socket.udp then
        self.ip_check=function(address)
            local s=socket.udp();if not s then return false end
            s:settimeout(0)
            local connected=s:setpeername(address,9)
            local current=connected and s:getsockname();s:close()
            return current==address
        end
    end
    self.url='http://'..self.authority..self.path
    self.html=Page.render(require('modules/baidu_auth').authorization_url(o.app_key,state),self.path,csrf)
    -- Network requests fork through KOReader Trapper. The child must not keep
    -- the parent's LAN listener alive after the UI cancels or expires it.
    local has_util,util=pcall(require,'ffi/util')
    if has_util and util.addRunInSubProcessAfterForkFunc and util.removeRunInSubProcessAfterForkFunc then
        self.fork_util=util;self.fork_key='baidupansync-auth-'..token
        util.addRunInSubProcessAfterForkFunc(self.fork_key,function()
            self.listener:close()
            for _,client in ipairs(self.clients) do client.socket:close() end
        end)
    end
    self.poll=function()self:poll_once();if not self.closed and self.schedule then self.schedule(0.1,self.poll) end end
    if self.schedule then self.schedule(0.1,self.poll) end
    return self
end
function M:stop(reason)
    if self.closed then return end
    self.closed=true
    if self.fork_util then self.fork_util.removeRunInSubProcessAfterForkFunc(self.fork_key) end
    if self.unschedule then self.unschedule(self.poll) end
    self.listener:close()
    for _,c in ipairs(self.clients) do c.socket:close();c.input=nil;c.output=nil end
    self.clients={};self.csrf=nil;self.html=nil;self.oauth_state=nil
    if self.on_stop then self.on_stop(reason or 'cancelled') end
end
function M:finish(e)
    if self.closed then return end
    self.state=e and 'failed' or 'success'
    self.message=e and ('授权失败：'..e.message..'。请在阅读器重新开始。') or '授权成功，凭据已安全保存到阅读器。'
    self.stop_at=self.now()+5
end
function M:handle(method,path,headers,body)
    if headers.host~=self.authority then return 403,'请求目标不匹配' end
    if headers.origin and headers.origin~='http://'..self.authority then return 403,'拒绝其他站点提交' end
    if path==self.path..'/status' and method=='GET' then
        return 200,self.state=='exchanging' and '正在校验并保存，请稍候…' or self.message
    end
    if path~=self.path then return 404,'页面不存在或已过期' end
    if method=='GET' then return 200,self.html,'text/html; charset=utf-8' end
    if method~='POST' then return 405,'只允许 GET 和 POST' end
    if self.state~='waiting' then return 409,'本次会话已提交，请查看阅读器结果' end
    if not (headers['content-type'] or ''):match('^application/x%-www%-form%-urlencoded') then return 415,'提交格式无效' end
    local form=M.form(body)
    if not form or form.csrf~=self.csrf or type(form.code)~='string' or #form.code<1 or #form.code>1024
        or form.code:find('%c') then return 400,'授权码或会话凭证无效' end
    self.state='exchanging';self.message='正在校验并保存，请稍候…'
    self.on_code(form.code,function(e)self:finish(e)end)
    form.code=nil
    return 202,'已接收授权码，正在校验并保存，请勿关闭阅读器。'
end
function M.response(code,body,content_type)
    return 'HTTP/1.1 '..code..' Response\r\nConnection: close\r\nContent-Length: '..#body..
        '\r\nContent-Type: '..(content_type or 'text/plain; charset=utf-8')..
        '\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff'..
        '\r\nContent-Security-Policy: default-src \'none\'; style-src \'unsafe-inline\'; script-src \'unsafe-inline\'; '..
        'connect-src \'self\'; form-action \'self\'; frame-ancestors \'none\'; base-uri \'none\'\r\n\r\n'..body
end
function M:parse(input)
    local ending=input:find('\r\n\r\n',1,true)
    if not ending then return #input>4096 and 431 or nil end
    if ending>4096 then return 431 end
    local head=input:sub(1,ending-1)
    local first,rest=head:match('^([^\r\n]+)\r\n(.*)$')
    local method,path
    if first then method,path=first:match('^(%u+) ([^%s]+) HTTP/1%.[01]$') end
    if not method then return 400 end
    local headers={}
    for line in (rest..'\r\n'):gmatch('(.-)\r\n') do
        local key,value=line:match('^([%w%-]+):%s*(.-)%s*$')
        if not key or headers[key:lower()] then return 400 end
        headers[key:lower()]=value
    end
    local length=headers['content-length'] or '0'
    if headers['transfer-encoding'] or not length:match('^%d+$') or #length>5 then return 400 end
    length=tonumber(length)
    if length>8192 then return 413 end
    local body=input:sub(ending+4)
    if #body<length then return nil end
    if #body~=length then return 400 end
    return self:handle(method,path,headers,body)
end
function M:poll_once()
    if self.closed then return end
    local now=self.now()
    if now>=self.deadline then return self:stop('expired') end
    if self.stop_at and now>=self.stop_at then return self:stop(self.state) end
    if self.ip_check and (not self.check_at or now>=self.check_at) then
        self.check_at=now+2
        if not self.ip_check(self.ip) then return self:stop('network_changed') end
    end
    if self.on_tick then self.on_tick(math.max(0,math.ceil(self.deadline-now)),self.state) end
    for _=1,4 do
        if #self.clients>=4 then break end
        local s=self.listener:accept();if not s then break end
        s:settimeout(0)
        self.clients[#self.clients+1]={socket=s,input='',until_time=now+5,sent=1}
    end
    for i=#self.clients,1,-1 do
        local c=self.clients[i]
        local drop=now>=c.until_time
        if not drop and not c.output then
            local data,e,partial=c.socket:receive(2048)
            c.input=c.input..(data or partial or '')
            if #c.input>12288 then c.output=M.response(413,'请求过大')
            else
                local code,body,kind=self:parse(c.input)
                if self.closed then return end
                if code then c.output=M.response(code,body or '请求无效',kind);c.input=nil
                elseif e=='closed' then drop=true end
            end
        end
        if not drop and c.output then
            local sent,e,last=c.socket:send(c.output,c.sent)
            c.sent=(sent or last or c.sent-1)+1
            if c.sent>#c.output or e=='closed' then drop=true end
        end
        if drop then c.socket:close();table.remove(self.clients,i) end
    end
end
return M
