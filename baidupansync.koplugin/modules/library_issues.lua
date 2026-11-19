-- A single view over existing diagnostics; operations revalidate every hint.
local M={}
function M.collect(result)
    local items={}
    for _,entry in ipairs(result.unpublished or {}) do
        items[#items+1]={title='未发布 · '..entry.book_id:sub(1,12)..'…',
            reason='EPUB 已存在，但没有书库发布记录。可整书校验后补全发布，或删除未发布 EPUB。',
            path=entry.path,repair=entry,cleanup={kind='unpublished',book_id=entry.book_id,path=entry.path,
                stat=entry.book_stat,backend_id=entry.backend_id}}
    end
    for _,entry in ipairs(result.entries or {}) do
        if entry.incomplete then
            items[#items+1]={title='文件异常 · '..entry.record.title,path=entry.record.path,entry=entry,
                reason='云端 EPUB 缺失或大小不符。重新上传原书可恢复；也可确认删除剩余云端文件与进度。'}
        end
    end
    for _,issue in ipairs(result.issues or {}) do
        if not issue.recoverable then
            local item={title='发布记录异常 · '..(issue.book_id and issue.book_id:sub(1,12)..'…' or issue.path),
                reason=issue.message,path=issue.path}
            if issue.cleanup_allowed and type(issue.book_id)=='string' and #issue.book_id==64
                and issue.book_id:match('^[0-9a-f]+$') and issue.stat then
                item.cleanup={kind='metadata',book_id=issue.book_id,path=issue.path,stat=issue.stat,backend_id=issue.backend_id}
                item.reason=item.reason..'。可清理该损坏记录，EPUB 和阅读进度保留；刷新后可校验补全发布。'
            else item.reason=item.reason..'。请升级插件或在网盘 / WebDAV 服务端核对；此条目不提供自动清理。' end
            items[#items+1]=item
        end
    end
    return items
end
return M
