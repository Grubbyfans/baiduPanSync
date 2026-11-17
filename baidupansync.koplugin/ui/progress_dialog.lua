--[[--
Dialogs for undo and full-book hashing.

Progress services stay UI-free; this module owns the progress dialogs.
]]

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local ProgressbarDialog = require("ui/widget/progressbardialog")
local UIManager = require("ui/uimanager")
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
    local closed=false
    local dialog=ProgressbarDialog:new{title=_("检查根目录及子目录的同名书籍"),
        subtitle=_("点击可取消；仅计算同名文件的完整摘要"),dismiss_text=_("取消同名检查？"),
        dismiss_callback=function()if not closed then cancelled=true end end}
    dialog:show()
    return {is_cancelled=function()return cancelled end,close=function()
        if closed then return end
        closed=true
        dialog:close()
    end}
end

return Dialog
