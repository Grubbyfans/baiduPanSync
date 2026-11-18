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
    local backend=info.backend_label or info.backend
    if info.kind=='repair_book' then
        local input
        input=Input:new{title='检查并补全发布\n'..backend..' / '..info.entry.path..
            '\n将回读并校验整书，仅补写书库记录，不修改 EPUB 或云端进度。\n请输入用于书库显示的书名：',
            input='恢复书籍-'..info.entry.book_id:sub(1,12),dismissable=false,buttons={{
                {text='取消',callback=function()UI:close(input);done(false)end},
                {text='校验并发布',callback=function()
                    local title=input:getInputText()
                    if not Meta.text(title) or not Meta.name(title) then return Dialog.info('请输入有效的书名') end
                    UI:close(input);done{title=title}
                end},
            }}}
        UI:show(input);input:onShowKeyboard();return
    end
    if info.kind=='delete_book' then
        local lines={'书籍：'..M.library_title(info.record),'服务位置：'..backend,
            '将删除云端 EPUB、书库记录和该书的云端阅读进度。本机已下载文件和阅读位置会保留。',
            '关联文件：\n'..table.concat(info.paths,'\n'),'删除后无法在插件内撤销。'}
        if info.best_effort then lines[#lines+1]='百度无法原子锁定删除目标，请避免其他设备同时上传或修改这本书。' end
        UI:show(Confirm:new{title=_('删除云端书籍'),text=table.concat(lines,'\n\n'),
            ok_text=_('确认删除'),cancel_text=_('取消'),ok_callback=function()done(true)end,cancel_callback=function()done(false)end})
        return
    end
    if info.kind=='progress_upload' or info.kind=='progress_download' then
        local remote=info.remote and info.remote.record
        local kinds={first_contact='首次关联',unchanged='与已确认版本一致',remote_changed='云端记录已变化',
            same_revision_different_record='相同修订号但内容不同',remote_created='云端新出现记录',remote_deleted='云端记录已删除'}
        local text=string.format('后端：%s\n书籍：%s\n本地位置：%s\n云端位置：%s\n版本比较：%s',
            backend,info.context.book.title or info.context.book.file_name,
            Dialog.percent_text(info.context.progress.percent),remote and Dialog.percent_text(remote.progress.percent) or '不存在',
            kinds[info.classification.kind] or '请重新核对')
        if remote then text=text..string.format('\n云端 revision：%d\n设备：%s\n设备时间：%s',remote.sync.revision,remote.sync.deviceId,remote.sync.updatedAt) end
        if info.best_effort then text=text..'\n此服务无法保证并发保护，请避免多台设备同时上传同一本书的进度。' end
        UI:show(Confirm:new{title=info.kind=='progress_upload' and _('上传当前进度') or _('下载并应用云端进度'),
            text=text,ok_text=_('确认'),cancel_text=_('取消'),ok_callback=function()done(true)end,cancel_callback=function()done(false)end})
        return
    end
    local buttons,dialog={},nil
    local lines={'后端：'..backend,'文件：'..info.filename}
    if info.kind=='download_book' then
        lines[#lines+1]='发现本地同名文件，请查看下方完整位置后选择覆盖、重命名或取消。任务会等待你的选择。覆盖不同内容会备份旧 EPUB 及已有阅读设置；启用 KOReader 哈希元数据存储时，覆盖后需重启再打开。'
        for i,candidate in ipairs(info.candidates) do
            local selected=candidate
            lines[#lines+1]=string.format('同名书籍 %d：\n%s\n%s',i,selected.path,
                selected.same and 'bookId 相同（内容一致）' or 'bookId 不同（内容不同）')
            buttons[#buttons+1]={{text=string.format('覆盖同名书籍 %d',i),callback=function()
                UI:close(dialog);done{mode='overwrite',path=selected.path}
            end}}
        end
    else
        lines[#lines+1]='云端同名/相同内容检查结果：'
        for _,candidate in ipairs(info.candidates) do
            local selected=candidate
            if not info.no_replace_other or selected.record.bookId==info.identity.book_id then
            buttons[#buttons+1]={{text='覆盖条目：'..Meta.filename(selected.record)..'\n'..
                (selected.record.bookId==info.identity.book_id and 'bookId 相同（内容一致）' or 'bookId 不同（内容不同）')..' · '..selected.record.bookId:sub(1,12)..'…',callback=function()
                UI:close(dialog);done{mode='overwrite',book_id=selected.record.bookId}
            end}}
            else lines[#lines+1]='已存在：'..Meta.filename(selected.record)..'（不同内容，请选择重命名保留两本）' end
        end
        if info.recovery then
            lines[#lines+1]='此 bookId 已有 EPUB 但未发布；继续将回读整本书校验后补全发布。'
            buttons[#buttons+1]={{text=_('检查并补全发布'),callback=function()
                UI:close(dialog);done{mode='overwrite',book_id=info.identity.book_id}
            end}}
        end
        lines[#lines+1]=info.no_replace_other and '百度不提供已验证的原子条件删除；不同内容的同名书籍请重命名保留两本。'
            or '不同内容覆盖会发布新 bookId 并撤下选中的旧书库条目；旧 EPUB 和进度保留，不迁移。'
    end
    buttons[#buttons+1]={{text=_('重命名'),callback=function()UI:close(dialog);rename(info.filename,done)end}}
    buttons[#buttons+1]={{text=_('跳过 / 取消'),callback=function()UI:close(dialog);done('cancel')end}}
    dialog=Buttons:new{title=table.concat(lines,'\n\n'),buttons=buttons,dismissable=false,rows_per_page=4}
    UI:show(dialog)
end
-- Filtering and sorting operate on a copy; download callbacks retain the exact
-- published entry (including its version snapshot).
function M.library_title(record)
    local title=type(record.title)=='string' and record.title:match('^%s*(.-)%s*$') or ''
    if title=='' then title=Meta.filename(record) end
    return (title:gsub('%.[Ee][Pp][Uu][Bb]$',''))
end
function M.library_entries(result,state)
    local entries={}
    local query=(state.query or ''):lower()
    for _,entry in ipairs(result.entries) do
        local record=entry.record
        if query=='' or Meta.filename(record):lower():find(query,1,true)
            or (record.title or ''):lower():find(query,1,true) then
            entries[#entries+1]=entry
        end
    end
    table.sort(entries,function(a,b)
        if state.order=='size' and a.record.size~=b.record.size then return a.record.size>b.record.size end
        local an,bn=M.library_title(a.record):lower(),M.library_title(b.record):lower()
        if an~=bn then return an<bn end
        local af,bf=Meta.filename(a.record):lower(),Meta.filename(b.record):lower()
        if af~=bf then return af<bf end
        return a.record.bookId<b.record.bookId
    end)
    return entries
end
function M.library(result,on_download,page,on_show,on_close,state,on_delete,on_repair,on_refresh,on_switch_backend)
    local grid=require('ui/library_grid'):new{result=result,on_download=on_download,
        page=page,state=state,on_close=on_close,title_for=M.library_title,filter=M.library_entries,on_delete=on_delete,
        on_repair=on_repair,on_refresh=on_refresh,on_switch_backend=on_switch_backend}
    if on_show then on_show(grid) end
    UI:show(grid)
    return grid
end
function M.query(result,context,actions)
    actions=actions or {}
    local record=result.remote and result.remote.record
    local lines={'阅读进度对比','书籍：'..(context.book.title or context.book.file_name),
        '后端：'..(result.backend_label or result.backend),'本机位置：'..Dialog.percent_text(context.progress.percent),
        '云端位置：'..(record and Dialog.percent_text(record.progress.percent) or '尚无记录')}
    if record then
        lines[#lines+1]='云端设备：'..record.sync.deviceId
        lines[#lines+1]='设备时间：'..record.sync.updatedAt
    end
    lines[#lines+1]='请选择同步方向，操作前会重新核对并确认。'
    local dialog
    local function select(action)return function()UI:close(dialog);if action then action()end end end
    dialog=Buttons:new{title=table.concat(lines,'\n'),buttons={
        {{text=_('上传本机进度 → 云端'),enabled=actions.upload~=nil,callback=select(actions.upload)}},
        {{text=_('应用云端进度 → 本机'),enabled=record~=nil and actions.download~=nil,callback=select(actions.download)}},
        {{text=_('刷新对比'),enabled=actions.refresh~=nil,callback=select(actions.refresh)},
         {text=_('撤销上次应用'),enabled=actions.undo~=nil,callback=select(actions.undo)}},
        {{text=_('返回'),callback=select()}},
    }}
    UI:show(dialog)
    return dialog
end
function M.downloaded(result,open,on_library)
    local text='已下载并校验：'..result.path..'\n不会自动应用云端进度。'
    if result.backup then text=text..'\n旧文件备份：'..result.backup end
    if result.metadata_backups and #result.metadata_backups>0 then
        text=text..'\n旧书阅读设置已原样备份（未应用到新内容）：'..result.metadata_backups[1].backup
    end
    if result.restart_required then
        return Dialog.result(_('书籍下载完成'),text..'\n请先重启 KOReader，再打开这本书，避免沿用旧路径的元数据缓存。',
            on_library and {{text=_('查看云端书库'),callback=on_library}} or {})
    end
    local actions={{text=_('打开书籍'),callback=function()open(result.path)end}}
    if on_library then actions[#actions+1]={text=_('查看云端书库'),callback=on_library} end
    return Dialog.result(_('书籍下载完成'),text,actions)
end
return M
