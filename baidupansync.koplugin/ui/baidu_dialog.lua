local UI=require('ui/uimanager')
local Buttons=require('ui/widget/buttondialog')
local MultiInput=require('ui/widget/multiinputdialog')
local Dialog=require('ui/progress_dialog')
local E=require('modules/errors')
local M={}
local function busy(plugin)return plugin.baidu_busy or plugin.dav_busy or plugin.undo_busy end
function M.configure(plugin)
    if busy(plugin) then return Dialog.info('请先完成或取消当前任务。') end
    local p,e=plugin.baidu_store:load();if e then return Dialog.error(e) end
    p=p or {}
    local input
    input=MultiInput:new{title='百度应用配置（C2）',fields={
        {text=p.app_key or '',hint='AppKey / API Key'},
        {text=p.secret_key or '',hint='SecretKey（只保存在阅读器）',text_type='password'},
        {text=p.app_dir or '',hint='实际应用目录，例如 /apps/你的应用名称'},
        {text=p.listen_ip or '',hint='阅读器局域网 IP（留空自动检测）'},
        {text=p.cafile or '',hint='CA 文件（留空使用系统可信 CA）'},
    },buttons={{
        {text='取消',callback=function()UI:close(input)end},
        {text='保存',callback=function()
            if busy(plugin) then return Dialog.info('请先完成或取消当前任务。') end
            local v=input:getFields()
            if v[4]~='' and not require('modules/baidu_auth_server').private_ip(v[4]) then return Dialog.info('请输入阅读器的局域网 IPv4 地址。') end
            local record=require('modules/baidu_store').prepare(p,{app_key=v[1],secret_key=v[2],app_dir=v[3],
                listen_ip=v[4]~='' and v[4] or nil,cafile=v[5]~='' and v[5] or nil})
            local ok,err=plugin.baidu_store:save(record)
            if not ok then return Dialog.error(err) end
            UI:close(input);plugin:refreshHome();Dialog.info('百度应用配置已保存。现在可开始扫码授权。')
        end},
    }}}
    UI:show(input);input:onShowKeyboard()
end
function M.authorize(plugin,phone_setup)
    if busy(plugin) then return Dialog.info('请先完成或取消当前任务。') end
    local p,e=plugin.baidu_store:load()
    if e then return Dialog.error(e) end
    phone_setup=phone_setup or not p
    p=p or {}
    if not phone_setup then
        local factory,reason=require('modules/dav_tls').factory(p.cafile)
        if not factory then return Dialog.error(E.new('TLS',reason)) end
    end
    if plugin.baidu_session then plugin.baidu_session:stop('replaced') end
    local server,auth,page
    local function finish(err)
        if server.closed then return end
        server:finish(err)
        if plugin.baidu_task=='auth' then plugin.baidu_busy=false;plugin.baidu_task=nil end
        if page and not page.closed then page.completed=true;page:close() end
        plugin:refreshHome()
        if err then Dialog.error(err)
        else Dialog.info('百度授权成功，已核对用户身份并保存凭据。\n可运行 C2 测试；百度书籍与进度同步尚未开放。') end
    end
    local function submit(code,done)
        if not auth then return done(E.new('CONFLICT','授权会话未就绪')) end
        auth:submit(code,function(err)done(err);finish(err)end)
    end
    local function make_auth()
        auth=require('modules/baidu_auth'):new{profile=p,store=plugin.baidu_store,
            deadline=os.time()+math.max(0,math.floor(server.deadline-server.now())),
            is_active=function()return not server.closed end}
    end
    local function configure(fields)
        local record=require('modules/baidu_store').prepare(p,{app_key=fields.app_key,secret_key=fields.secret_key,
            app_dir=fields.app_dir,listen_ip=p.listen_ip,cafile=p.cafile})
        local ok,err=plugin.baidu_store:save(record)
        if not ok then return nil,err end
        p=record
        local factory,reason=require('modules/dav_tls').factory(p.cafile)
        if not factory then return nil,E.new('TLS',reason..'；配置已保存，请在阅读器检查 CA 后重新开始') end
        make_auth()
        return require('modules/baidu_auth').authorization_url(p.app_key,server.oauth_state)
    end
    local start_error
    server,start_error=require('modules/baidu_auth_server').start{ip=p.listen_ip,app_key=p.app_key,
        schedule=function(delay,cb)UI:scheduleIn(delay,cb)end,unschedule=function(cb)UI:unschedule(cb)end,
        on_config=phone_setup and configure or nil,
        public_profile={app_key=p.app_key,app_dir=p.app_dir,has_secret=p.secret_key~=nil},
        on_code=submit,on_tick=function(seconds,state)if page then page:update(seconds,state)end end,
        on_stop=function(reason_code)
            if auth and auth.state~='success' and auth.state~='failed' then auth:cancel() end
            if plugin.baidu_session==server then
                plugin.baidu_session=nil
                if plugin.baidu_task=='auth' then plugin.baidu_busy=false;plugin.baidu_task=nil end
                if page and not page.closed then page.completed=true;page:close() end
                plugin:refreshHome()
                if reason_code=='expired' then Dialog.info('百度授权已超时，请重新开始。')
                elseif reason_code=='network_changed' then Dialog.info('网络已变化，请重新开始授权。') end
            end
        end}
    if not server then return Dialog.error(start_error) end
    if not phone_setup then make_auth() end
    local ok,created=pcall(function()return require('ui/baidu_auth_dialog'):new{session=server,on_cancel=function(reason_code)
        if auth then auth:cancel() end;server:stop(reason_code or 'cancelled')
    end,on_code=function(code)
        if server.state~='waiting' then return Dialog.info('授权码已提交，请等待结果。') end
        server.state='exchanging';submit(code,function(err)server:finish(err)end)
    end}end)
    if not ok then if auth then auth:cancel() end;server:stop('failed');return Dialog.error(E.new('IO','无法显示授权二维码，请检查 KOReader 版本')) end
    page=created
    plugin.baidu_session=server;plugin.baidu_busy=true;plugin.baidu_task='auth'
    UI:show(page);plugin:refreshHome()
end
function M.probe(plugin)
    if busy(plugin) then return Dialog.info('请先完成或取消当前任务。') end
    local p,e=plugin.baidu_store:load();if e then return Dialog.error(e) end
    if not p or not p.user_id then return Dialog.info('请先完成百度扫码授权。') end
    local api,err=require('modules/baidu_api'):new(p);if not api then return Dialog.error(err) end
    plugin.baidu_busy=true;plugin.baidu_task='probe';plugin:refreshHome()
    require('modules/baidu_probe').run(api,function(probe_err,result)
        plugin.baidu_busy=false;plugin.baidu_task=nil;plugin:refreshHome()
        if probe_err then return Dialog.error(probe_err,result.directory and
            ('本次随机测试目录：'..result.directory..'\n如有残留，请在百度网盘核对清理。') or nil) end
        p.last_probe=result
        local saved,save_err=plugin.baidu_store:save(p)
        if not saved then return Dialog.error(save_err,'测试已完成，但本地验收记录保存失败。') end
        Dialog.info('百度 C2 测试通过：用户身份、建目录、上传、枚举、下载回读及删除测试 JSON。\n'..
            '目录：'..result.directory..'\n测试文件已删除，空测试目录保留。\n'..
            '未验证原子条件写入，未接入真实书籍或进度同步。')
    end)
end
function M.show(plugin)
    local p,e=plugin.baidu_store:load();if e then return Dialog.error(e) end
    local status=not p and '请先配置应用' or not p.user_id and '应用已配置，尚未授权'
        or (type(p.expires_at)~='number' or os.time()>=p.expires_at-30) and '授权已过期，请重新授权'
        or ('已授权：'..(p.account_name~='' and p.account_name or p.user_id))
    local dialog
    local function run(fn)UI:close(dialog);fn(plugin)end
    dialog=Buttons:new{title='百度网盘 · C2 接入验证\n'..status..'\n当前后端：'..
        (plugin.active_backend=='baidu' and '百度（C2，仅授权与测试）' or 'WebDAV'),buttons={
        {{text='手机扫码配置与授权',callback=function()UI:close(dialog);M.authorize(plugin,true)end}},
        {{text='在阅读器配置应用',callback=function()run(M.configure)end}},
        {{text='使用现有配置授权 / 重新授权',callback=function()run(M.authorize)end}},
        {{text='验证测试文件上传与下载',callback=function()run(M.probe)end}},
        {{text='返回连接设置',callback=function()UI:close(dialog)end}},
    }}
    UI:show(dialog)
end
function M.switch_backend(plugin)
    if busy(plugin) then return Dialog.info('请先完成或取消当前任务。') end
    local p,e=plugin.baidu_store:load();if e then return Dialog.error(e) end
    local ready=p and p.backend_id and p.last_probe and p.last_probe.backend_id==p.backend_id
        and type(p.expires_at)=='number' and os.time()<p.expires_at-30
    local dialog
    local function choose(kind,id)
        if busy(plugin) then return Dialog.info('请先完成或取消当前任务。') end
        if kind=='baidu' and os.time()>=p.expires_at-30 then return Dialog.info('百度授权已过期，请重新授权并测试。') end
        local state,err=plugin.config:_read();if not state then return Dialog.error(err) end
        state.data.activeBackendType=kind;state.data.activeBackendId=id
        local ok,save_err=plugin.config:_write(state);if not ok then return Dialog.error(save_err) end
        plugin.active_backend=kind
        if plugin.library_dialog then UI:close(plugin.library_dialog) end
        UI:close(dialog);plugin:refreshHome()
        Dialog.info(kind=='baidu' and '已切换到百度 C2。只开放授权与测试，书籍和阅读进度操作暂不可用；不会改为写入 WebDAV。'
            or '已切换到 WebDAV。请重新打开云端书库或查询进度。')
    end
    dialog=Buttons:new{title='切换后端\n各后端凭据与进度基线独立，不迁移数据。',buttons={
        {{text='WebDAV',enabled=plugin.dav_adapter~=nil,callback=function()
            if plugin.dav_adapter then choose('webdav',plugin.dav_adapter.backend_id) end
        end}},
        {{text=ready and '百度网盘（C2，仅授权与测试）' or '百度网盘（请先授权并通过 C2 测试）',enabled=ready and true or false,
            callback=function()if ready then choose('baidu',p.backend_id) end end}},
        {{text='取消',callback=function()UI:close(dialog)end}},
    }}
    UI:show(dialog)
end
return M
