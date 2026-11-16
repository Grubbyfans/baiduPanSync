--[[--
BaiduPanSync plugin entry point — Stage A only.

Scope of this stage (spec 9, stage A):
- plugin skeleton and reader menu;
- recognize the currently opened EPUB;
- read XPointer and (optional) percent;
- export/import a local progress JSON record;
- navigate, verify and undo — without any remote backend.

Cloud backends, full SHA-256 identity and the sync engine belong to later stages
and are intentionally absent here.
]]

local DataStorage = require("datastorage")
local Event = require("ui/event")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local _ = require("gettext")

local ExportStore = require("modules/export_store")
local LocalStore = require("modules/storage")
local ProgressRecord = require("modules/progress_record")
local ProgressService = require("modules/progress")
local Dialog = require("ui/progress_dialog")
local Menu = require("ui/menu")

local T = ffiUtil.template
local VERSION = "0.1.0"

local BaiduPanSync = WidgetContainer:extend{
    name = "baidupansync",
    is_doc_only = true,
    version = VERSION,
}

local MISMATCH_REASONS = {
    size = _("书籍大小不一致"),
    partialMd5 = _("partial MD5 不一致"),
    name = _("书名或文件名不一致"),
    invalid = _("记录无效"),
}

function BaiduPanSync:init()
    self.settings_dir = DataStorage:getSettingsDir() .. "/baidupansync"
    self.exports_dir = self.settings_dir .. "/exports"
    self.store = LocalStore:new{ dir = self.settings_dir }
    self.exports = ExportStore:new{ dir = self.exports_dir }
    self.progress = ProgressService:new{
        reader_ui = self.ui,
        store = self.store,
        event = Event,
    }
    self.ui.menu:registerToMainMenu(self)
end

function BaiduPanSync:addToMainMenu(menu_items)
    menu_items.baidupansync = Menu.build(self)
end

function BaiduPanSync:isCurrentBookSupported()
    return self.progress:is_supported() and true or false
end

function BaiduPanSync:hasRestorePoint()
    return self.progress:has_restore_point()
end

function BaiduPanSync:onExportProgress()
    local context, err = self.progress:capture()
    if not context then return Dialog.error(err) end
    local record, record_err = ProgressRecord.from_capture(context)
    if not record then return Dialog.error(record_err) end
    local path, save_err = self.exports:save(record)
    if not path then return Dialog.error(save_err) end
    Dialog.info(T(_("已导出阅读进度：%1\n书籍：%2\n文件：%3"),
        Dialog.percent_text(context.progress.percent),
        context.book.title or context.book.file_name,
        path))
end

function BaiduPanSync:onImportProgress()
    local context, err = self.progress:capture()
    if not context then return Dialog.error(err) end
    local entries, list_err = self.exports:list(10)
    if not entries then return Dialog.error(list_err) end
    if #entries == 0 then
        return Dialog.info(T(_("导出目录为空。请先导出进度，或将 JSON 文件复制到：\n%1"),
            self.exports:get_dir()))
    end
    Dialog.choose_record(entries, function(entry)
        self:_confirmImport(entry, context)
    end)
end

function BaiduPanSync:_confirmImport(entry, context)
    local record = entry.record
    local matches, reason = ProgressRecord.matches_book(record, context.book)
    if not matches then
        return Dialog.error(T(_("这不是当前书籍的进度记录：%1"),
            MISMATCH_REASONS[reason] or tostring(reason)))
    end
    Dialog.confirm_import(record, context, function()
        self.progress:apply(context, record.progress, function(apply_err, result)
            if apply_err then
                local extra
                if result and result.rollback then
                    extra = _("已尝试回到导入前的位置。")
                end
                return Dialog.error(apply_err, extra)
            end
            if result and result.no_navigation then
                return Dialog.info(_("导入位置与当前阅读位置相同，无需跳转。"))
            end
            Dialog.info(T(_("已恢复到导入位置：%1\n可使用“撤销上次进度恢复”返回。"),
                Dialog.percent_text(record.progress.percent)))
        end)
    end)
end

function BaiduPanSync:onUndoRestore()
    local restore_point, rp_err = self.store:get_restore_point()
    if rp_err then return Dialog.error(rp_err) end
    if not restore_point then
        return Dialog.info(_("没有可撤销的进度恢复点。"))
    end
    Dialog.confirm_undo(restore_point, function()
        self.progress:undo(function(undo_err, result)
            if undo_err then
                local extra
                if result and result.rollback then
                    extra = _("已尝试回到撤销前的位置。")
                end
                return Dialog.error(undo_err, extra)
            end
            if result and result.no_navigation then
                return Dialog.info(_("当前位置已在恢复点，无需跳转。"))
            end
            local message = T(_("已撤销上次进度恢复：%1"),
                Dialog.percent_text(restore_point.position.percent))
            if result and result.warning then
                message = message .. "\n" .. _("恢复点清理失败，可稍后重试。")
            end
            Dialog.info(message)
        end)
    end)
end

return BaiduPanSync
