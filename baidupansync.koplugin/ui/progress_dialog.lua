--[[--
Dialogs for progress export/import/undo and full-book hashing.

ProgressService/SyncEngine stay UI-free; this module owns all Stage B text,
including the conflict information computed by `conflict.lua`.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local ProgressbarDialog = require("ui/widget/progressbardialog")
local UIManager = require("ui/uimanager")
local datetime = require("datetime")
local _ = require("gettext")

local Dialog = {}

function Dialog.percent_text(percent)
    if type(percent) ~= "number" then
        return _("未知")
    end
    return string.format("%.1f%%", percent * 100)
end

function Dialog.book_text(record_or_book)
    local book = record_or_book.book or record_or_book
    local title = book.title or book.fileName or _("未知书名")
    return title
end

function Dialog.short_hash(hash)
    if type(hash) ~= "string" then return _("未知") end
    return hash:sub(1, 16) .. "…"
end

function Dialog.error(err, extra)
    local message
    if type(err) == "table" and err.message then
        message = err.message
        if err.code then
            message = string.format("%s（%s）", message, err.code)
        end
    else
        message = tostring(err)
    end
    if extra then
        message = message .. "\n" .. extra
    end
    UIManager:show(InfoMessage:new{
        text = message,
        timeout = 10,
    })
end

function Dialog.info(text)
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = 8,
    })
end

--- Lists importable records. Invalid files are selectable and explain why.
function Dialog.choose_record(entries, on_select)
    local dialog
    local buttons = {}
    for _, entry in ipairs(entries) do
        local label
        if entry.valid then
            local record = entry.record
            label = string.format("%s\n%s  ·  rev %d  ·  %s",
                Dialog.book_text(record),
                Dialog.percent_text(record.progress.percent),
                record.sync.revision,
                entry.mtime and datetime.secondsToDateTime(entry.mtime) or entry.name)
        else
            label = string.format("%s\n%s", _("（无效记录）"), entry.name)
        end
        table.insert(buttons, {{
            text = label,
            callback = function()
                UIManager:close(dialog)
                if entry.valid then
                    on_select(entry)
                else
                    Dialog.error(entry.error)
                end
            end,
        }})
    end
    table.insert(buttons, {{
        text = _("取消"),
        callback = function() UIManager:close(dialog) end,
    }})
    dialog = ButtonDialog:new{
        title = _("选择要导入的进度记录"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

local CONFLICT_TEXT = {
    first_contact = _("首次关联：本地没有该书的已确认记录，确认后将保存为基线。"),
    unchanged = _("记录与上次已确认版本一致。"),
    remote_changed = _("记录已变化（内容或修订号不同），请确认是否使用此版本。"),
    same_revision_different_record = _("同一 revision 下记录内容不同，存在并发写入迹象，请确认。"),
    remote_created = _("本地基线为空，但出现了记录。"),
    remote_deleted = _("基线存在但记录缺失。"),
}

--- Confirmation / conflict dialog for an imported record.
-- @tparam table record validated cloud progress record
-- @tparam table info SyncEngine confirmation info
-- @tparam function on_accept
-- @tparam function on_decline called on Cancel/dismiss
function Dialog.confirm_import(record, info, on_accept, on_decline)
    local classification = info and info.classification
    local kind = classification and classification.kind or "first_contact"
    local baseline_revision
    if info and info.baseline and info.baseline.remote_state == "present" then
        baseline_revision = info.baseline.base_revision
    end

    local lines = {
        string.format(_("书籍：%s"), Dialog.book_text(record)),
        string.format(_("内容摘要：sha256:%s"), Dialog.short_hash(record.book.contentSha256)),
        string.format(_("导入位置：%s"), Dialog.percent_text(record.progress.percent)),
        string.format(_("当前位置：%s"), Dialog.percent_text(info and info.context and info.context.progress.percent)),
        string.format(_("记录：revision %d  ·  设备 %s  ·  %s"),
            record.sync.revision,
            record.sync.deviceId,
            record.sync.updatedAt),
        CONFLICT_TEXT[kind] or _("请确认是否使用该记录。"),
    }
    if baseline_revision then
        table.insert(lines, string.format(_("本地基线 revision：%d"), baseline_revision))
    end
    table.insert(lines, _("恢复失败时会尝试回到原位置；只有成功后才更新本地基线。"))

    UIManager:show(ConfirmBox:new{
        title = _("导入并恢复阅读位置"),
        text = table.concat(lines, "\n\n"),
        ok_text = _("恢复"),
        cancel_text = _("取消"),
        ok_callback = on_accept,
        cancel_callback = function()
            if on_decline then on_decline() end
        end,
    })
end

function Dialog.confirm_undo(restore_point, on_confirm)
    local text = string.format(
        "%s\n\n%s\n%s\n\n%s",
        string.format(_("书籍：%s"), Dialog.book_text(restore_point.book)),
        string.format(_("返回到：%s"), Dialog.percent_text(restore_point.position.percent)),
        restore_point.created_at and string.format(_("恢复点时间：%s"), restore_point.created_at) or "",
        _("撤销只恢复本机阅读位置，不会上传或修改云端数据。"))
    UIManager:show(ConfirmBox:new{
        title = _("撤销上次进度恢复"),
        text = text,
        ok_text = _("撤销"),
        cancel_text = _("取消"),
        ok_callback = on_confirm,
    })
end

--- Shows a cancelable hash progress dialog and returns a small handle.
-- The engine closes it through on_hash_finish; a user cancel only sets a flag
-- that the hashing loop observes between chunks.
function Dialog.start_hash_progress(total)
    local cancelled = false
    local closed = false
    local dialog = ProgressbarDialog:new{
        title = _("正在计算书籍摘要"),
        subtitle = _("用于确认书籍内容身份（SHA-256）"),
        progress_max = math.max(total or 0, 1),
        refresh_time_seconds = 0.2,
        dismissable = true,
        dismiss_text = _("要取消计算吗？取消后不会保存摘要。"),
        dismiss_callback = function()
            if not closed then cancelled = true end
        end,
    }
    dialog:show()

    local handle = {}
    function handle:report(done)
        if closed then return end
        dialog:reportProgress(math.min(done or 0, total or 0))
    end
    function handle:close()
        if closed then return end
        closed = true
        dialog:close()
    end
    function handle:is_cancelled()
        return cancelled
    end
    return handle
end

function Dialog.start_scan_progress()
    local cancelled=false
    local dialog=ProgressbarDialog:new{title=_("检查根目录及子目录的同名书籍"),
        subtitle=_("点击可取消；仅计算同名文件的完整摘要"),dismiss_text=_("取消同名检查？"),
        dismiss_callback=function()cancelled=true end}
    dialog:show()
    return {is_cancelled=function()return cancelled end,close=function()dialog:close()end}
end

return Dialog
