local UIManager=require('ui/uimanager')
local MultiInputDialog=require('ui/widget/multiinputdialog')
local Dialog=require('ui/progress_dialog')
local M={}
function M.configure(plugin)
    if plugin.dav_busy or plugin.undo_busy then return Dialog.info('连接测试进行中，不能修改目标。') end
    if plugin.dav_load_error then Dialog.error(plugin.dav_load_error) end
    local profile=plugin.dav_profile or {}
    local input
    input=MultiInputDialog:new{
        title='WebDAV 配置',
        fields={
            {text=profile.root_url or '',hint='根 URL，例如 http://192.168.1.2:8080/sync/'},
            {text=profile.username or '',hint='用户名'},
            {text=profile.password or '',hint='密码',text_type='password'},
            {text=profile.cafile or '',hint='CA 文件（留空使用系统可信 CA）'},
        },
        buttons={{
            {text='取消',callback=function() UIManager:close(input) end},
            {text='保存',callback=function()
                local values=input:getFields()
                local next_profile={root_url=values[1],username=values[2],password=values[3],cafile=values[4]~='' and values[4] or nil}
                local adapter,e=require('modules/webdav'):new(next_profile)
                if not adapter then return Dialog.error(e) end
                next_profile.type='webdav'
                local saved,save_err=plugin.backend_store:save(next_profile)
                if not saved then return Dialog.error(save_err) end
                plugin.dav_load_error=nil
                plugin.dav_profile=next_profile
                plugin.dav_adapter=adapter
                UIManager:close(input)
                plugin:refreshHome()
                Dialog.info('配置已保存，凭据单独存放。全部同步由你手动触发。\nHTTP 不加密，请仅用于可信局域网；HTTPS 强制验证 CA、证书链及 SAN，目标真机兼容性仍待验收。')
            end},
        }},
    }
    UIManager:show(input)
    input:onShowKeyboard()
end
function M.probe(plugin)
    if plugin.dav_busy or plugin.undo_busy then return Dialog.info('已有连接测试在执行。') end
    if not plugin.dav_adapter then return Dialog.info('请先配置 WebDAV。') end
    plugin.dav_busy=true
    local adapter=plugin.dav_adapter -- fixed target for the whole task
    require('modules/dav_probe').run(adapter,function(e,report)
        plugin.dav_busy=false
        plugin:refreshHome()
        if e then
            return Dialog.error(e,report and ('探测目录：'..report.directory..'\n仅包含本次随机测试数据，可在服务端核对清理。'))
        end
        Dialog.info('WebDAV 测试 JSON 上传、查询、枚举、下载及条件写入通过。\n'..
            '结果仅适用于本次服务与会话，不代表目标真机或公网服务验收通过。\n探测目录：'..report.directory..
            (report.cleanup_error and '\n测试文件清理失败，请在服务端核对。' or '\n测试文件已清理，空探测目录保留。'))
    end)
end
return M
