--[[--
Dialogs for the Stage A local progress round-trip.

This module owns all UI text for export/import/undo; ProgressService stays free
of UI imports so that its navigation logic can be tested headlessly.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
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
        timeout = 8,
    })
end

function Dialog.info(text)
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = 6,
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
            label = string.format("%s\n%s  ·  %s",
                Dialog.book_text(record),
                Dialog.percent_text(record.progress.percent),
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

function Dialog.confirm_import(record, context, on_confirm)
    local text = string.format(
        "%s\n\n%s\n%s\n\n%s",
        string.format(_("书籍：%s"), Dialog.book_text(record)),
        string.format(_("导入位置：%s"), Dialog.percent_text(record.progress.percent)),
        string.format(_("当前位置：%s"), Dialog.percent_text(context.progress.percent)),
        _("此记录是阶段 A 本地记录，不含完整内容摘要，仅用于同机往返验证。恢复失败时会尝试回到原位置。"))
    UIManager:show(ConfirmBox:new{
        title = _("导入并恢复阅读位置"),
        text = text,
        ok_text = _("恢复"),
        cancel_text = _("取消"),
        ok_callback = on_confirm,
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

return Dialog
