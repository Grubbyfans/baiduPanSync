-- OOB code exchange and identity verification. Manual code entry cannot
-- cryptographically correlate OAuth state; the LAN session protects submission.
local H=require('modules/baidu_http')
local A=require('modules/async')
local E=require('modules/errors')
local API=require('modules/baidu_api')
local M={};M.__index=M
function M:new(o)
    return setmetatable({profile=o.profile,store=o.store,transport=o.transport,now=o.now or os.time,
        deadline=o.deadline or os.time()+600,is_active=o.is_active or function()return true end,
        state='waiting'},self)
end
function M.authorization_url(key,state)
    return 'https://openapi.baidu.com/oauth/2.0/authorize?'..H.form{
        response_type='code',client_id=key,redirect_uri='oob',scope='basic,netdisk',state=state,display='mobile'}
end
function M:cancel()self.state='cancelled' end
function M:guard()
    if self.state=='cancelled' or not self.is_active() or self.now()>=self.deadline then
        error(E.new('CANCELLED','授权已取消或过期，请重新开始'),0)
    end
end
function M:submit(code,done)
    if self.state~='waiting' then return done(E.new('CONFLICT','本次授权已提交，请勿重复提交')) end
    if type(code)~='string' then return done(E.new('INVALID_INPUT','授权码无效')) end
    code=code:match('^%s*(.-)%s*$')
    if #code<1 or #code>1024 or not code:match('^[%w_%.%-]+$') then return done(E.new('INVALID_INPUT','请只粘贴授权码，不要粘贴完整网址')) end
    self.state='exchanging'
    A.run(function()
        self:guard()
        local p=self.profile
        local obtained=self.now()
        local token=A.call(function(cb)H.request({transport=self.transport,cafile=p.cafile,
            url='https://openapi.baidu.com/oauth/2.0/token?'..H.form{grant_type='authorization_code',
                code=code,client_id=p.app_key,client_secret=p.secret_key,redirect_uri='oob'}},cb)end)
        code=nil
        self:guard()
        local scope=type(token.scope)=='string' and (','..token.scope:gsub('%s+',',')..',') or ''
        if type(token.access_token)~='string' or #token.access_token<1 or #token.access_token>4096
            or type(token.expires_in)~='number' or token.expires_in<=60 or token.expires_in>315360000
            or token.expires_in%1~=0 or not scope:find(',netdisk,',1,true) then
            error(E.new('AUTH','百度未授予有效的网盘访问权限，请检查应用权限后重新授权'),0)
        end
        local record={app_key=p.app_key,secret_key=p.secret_key,app_dir=API.root(p.app_dir),cafile=p.cafile,
            access_token=token.access_token,obtained_at=obtained,expires_at=obtained+token.expires_in,
            scope=token.scope,listen_ip=p.listen_ip}
        if type(token.refresh_token)=='string' and #token.refresh_token<=4096 then record.refresh_token=token.refresh_token end
        local api=A.check(API:new(record));api.transport=self.transport;api.now=self.now
        local info=A.call(function(cb)api:user_info(cb)end)
        self:guard()
        record.user_id=info.user_id;record.account_name=info.name
        record.backend_id=A.check(require('modules/backend_identity').compute{
            type='baidu',app_key=record.app_key,app_dir=record.app_dir,user_id=record.user_id})
        A.check(self.store:save(record))
        return {account_name=record.account_name,user_id=record.user_id,expires_at=record.expires_at}
    end,function(e,v)
        if self.state=='cancelled' then return done(E.new('CANCELLED','本次授权已取消')) end
        self.state=e and 'failed' or 'success'
        done(e,v)
    end)
end
return M
