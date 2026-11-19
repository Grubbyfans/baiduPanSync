local M={}
function M.text(result)
    local source=result.refreshing and '正在更新书库' or result.cached and '本机缓存' or '云端最新列表'
    local updated=type(result.updated_at)=='number' and os.date('%Y-%m-%d %H:%M',result.updated_at) or '尚未成功获取'
    local text=source..' · 最近更新：'..updated
    if result.refresh_error then text=text..'\n更新失败，仍显示旧列表；原因见“书库信息”，可点击“主动更新书库”重试。'end
    return text
end
return M
