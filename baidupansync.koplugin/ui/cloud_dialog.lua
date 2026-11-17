local UI=require('ui/uimanager')
local Buttons=require('ui/widget/buttondialog')
local Confirm=require('ui/widget/confirmbox')
local Input=require('ui/widget/inputdialog')
local Dialog=require('ui/progress_dialog')
local Meta=require('modules/book_metadata')
local _=require('gettext')
local M={}
local function rename(filename,done)
    local input
    input=Input:new{title=_('重命名书籍'),input=filename,dismissable=false,buttons={{
        {text=_('取消'),callback=function()UI:close(input);done('cancel')end},
        {text=_('确定'),callback=function()
            local name=Meta.name(input:getInputText())
            if not name then return Dialog.info(_('文件名无效')) end
            UI:close(input);done{mode='rename',name=name}
        end},
    }}}
    UI:show(input);input:onShowKeyboard()
end
function M.confirm(info,done)
    if info.kind=='progress_upload' or info.kind=='progress_download' then
        local remote=info.remote and info.remote.record
        local kinds={first_contact='首次关联',unchanged='与已确认版本一致',remote_changed='云端记录已变化',
            same_revision_different_record='相同修订号但内容不同',remote_created='云端新出现记录',remote_deleted='云端记录已删除'}
        local text=string.format('后端：%s\n书籍：%s\n本地位置：%s\n云端位置：%s\n版本比较：%s',
            info.backend,info.context.book.title or info.context.book.file_name,
            Dialog.percent_text(info.context.progress.percent),remote and Dialog.percent_text(remote.progress.percent) or '不存在',
            kinds[info.classification.kind] or '请重新核对')
        if remote then text=text..string.format('\n云端 revision：%d\n设备：%s\n设备时间：%s',remote.sync.revision,remote.sync.deviceId,remote.sync.updatedAt) end
        if info.best_effort then text=text..'\n服务无已验证的条件写入，仅尽力避免并发覆盖。' end
        UI:show(Confirm:new{title=info.kind=='progress_upload' and _('上传当前进度') or _('下载并应用云端进度'),
            text=text,ok_text=_('确认'),cancel_text=_('取消'),ok_callback=function()done(true)end,cancel_callback=function()done(false)end})
        return
    end
    local buttons,dialog={},nil
    local lines={'后端：'..info.backend,'文件：'..info.filename}
    if info.kind=='download_book' then
        lines[#lines+1]='发现本地同名文件，请查看摘要结果后选择。覆盖不同内容会备份旧 EPUB 及已有阅读设置；启用 KOReader 哈希元数据存储时，覆盖后需重启再打开。'
        for _,candidate in ipairs(info.candidates) do
            local selected=candidate
            buttons[#buttons+1]={{text='覆盖：'..selected.path..'\n'..(selected.same and 'bookId 相同（内容一致）' or 'bookId 不同（内容不同）'),callback=function()
                UI:close(dialog);done{mode='overwrite',path=selected.path}
            end}}
        end
    else
        lines[#lines+1]='云端同名/相同内容检查结果：'
        for _,candidate in ipairs(info.candidates) do
            local selected=candidate
            buttons[#buttons+1]={{text='覆盖条目：'..Meta.filename(selected.record)..'\n'..
                (selected.record.bookId==info.identity.book_id and 'bookId 相同（内容一致）' or 'bookId 不同（内容不同）')..' · '..selected.record.bookId:sub(1,12)..'…',callback=function()
                UI:close(dialog);done{mode='overwrite',book_id=selected.record.bookId}
            end}}
        end
        if info.recovery then
            lines[#lines+1]='此 bookId 已有 EPUB 但未发布；继续将回读整本书校验后补全发布。'
            buttons[#buttons+1]={{text=_('检查并补全发布'),callback=function()
                UI:close(dialog);done{mode='overwrite',book_id=info.identity.book_id}
            end}}
        end
        lines[#lines+1]='不同内容覆盖会发布新 bookId 并撤下选中的旧书库条目；旧 EPUB 和进度保留，不迁移。'
    end
    buttons[#buttons+1]={{text=_('重命名'),callback=function()UI:close(dialog);rename(info.filename,done)end}}
    buttons[#buttons+1]={{text=_('跳过 / 取消'),callback=function()UI:close(dialog);done('cancel')end}}
    dialog=Buttons:new{title=table.concat(lines,'\n\n'),buttons=buttons,dismissable=false,rows_per_page=4}
    UI:show(dialog)
end
function M.library(result,on_download,page,on_show,on_close)
    page=page or 1
    local dialog,buttons=nil,{}
    for i=(page-1)*8+1,math.min(page*8,#result.entries) do
        local entry=result.entries[i]
        buttons[#buttons+1]={{text=string.format('%s\n%.2f MiB · %s…',Meta.filename(entry.record),entry.record.size/1048576,entry.record.bookId:sub(1,12)),
            callback=function()on_download(entry)end}}
    end
    local pages={}
    if page>1 then pages[#pages+1]={text=_('上一页'),callback=function()UI:close(dialog);M.library(result,on_download,page-1,on_show,on_close)end} end
    if page*8<#result.entries then pages[#pages+1]={text=_('下一页'),callback=function()UI:close(dialog);M.library(result,on_download,page+1,on_show,on_close)end} end
    if #pages>0 then buttons[#buttons+1]=pages end
    buttons[#buttons+1]={{text=_('返回插件主页'),callback=function()UI:close(dialog)end}}
    dialog=Buttons:new{title=string.format('云端书库 · %d 本 · 第 %d 页\n%s\n未完成/损坏记录：%d',#result.entries,page,result.backend,#result.issues),buttons=buttons}
    local closed=dialog.onCloseWidget
    dialog.onCloseWidget=function(self)
        if closed then closed(self) end
        if on_close then on_close(self) end
    end
    if on_show then on_show(dialog) end
    UI:show(dialog)
    return dialog
end
function M.query(result)
    if not result.remote then return Dialog.info(_('云端尚无当前书籍的阅读进度。')) end
    local record=result.remote.record
    Dialog.info(string.format('后端：%s\n云端位置：%s\n修订：%d\n设备：%s\n设备时间：%s',
        result.backend,Dialog.percent_text(record.progress.percent),
        record.sync.revision,record.sync.deviceId,record.sync.updatedAt))
end
function M.downloaded(result,open)
    local text='已下载并校验：'..result.path..'\n不会自动应用云端进度。'
    if result.backup then text=text..'\n旧文件备份：'..result.backup end
    if result.metadata_backups and #result.metadata_backups>0 then
        text=text..'\n旧书阅读设置已原样备份（未应用到新内容）：'..result.metadata_backups[1].backup
    end
    if result.restart_required then
        return Dialog.info(text..'\n请先重启 KOReader，再打开这本书，避免沿用旧路径的元数据缓存。')
    end
    UI:show(Confirm:new{title=_('书籍下载完成'),text=text,ok_text=_('打开书籍'),cancel_text=_('稍后'),ok_callback=function()open(result.path)end})
end
return M
