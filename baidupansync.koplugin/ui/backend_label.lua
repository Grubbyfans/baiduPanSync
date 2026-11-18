-- Presentation only: never show credentials or signed URL query strings.
local M={}
local function text(value)
    return type(value)=='string' and value:gsub('%c',' '):match('^%s*(.-)%s*$') or ''
end
function M.for_backend(backend)
    backend=backend or {}
    if backend.kind=='baidu' then
        local profile=backend.profile or {}
        local account=text(profile.account_name)
        if account=='' then account=text(profile.user_id) end
        return '百度网盘'..(account~='' and (' · '..account) or ' · 待授权')
    end
    local root=text(backend.root)
    local host=root:match('^https?://([^/?#]+)')
    if not host then return 'WebDAV' end
    host=host:gsub('^.*@','')
    local path=root:match('^https?://[^/?#]+([^?#]*)') or ''
    return 'WebDAV · '..host..path
end
function M.for_plugin(plugin)
    if plugin.active_backend=='baidu' then
        local profile=plugin.baidu_store and plugin.baidu_store:load()
        return M.for_backend{kind='baidu',profile=profile}
    end
    return M.for_backend{root=plugin.dav_adapter and plugin.dav_adapter.root
        or plugin.dav_profile and plugin.dav_profile.root_url}
end
return M
