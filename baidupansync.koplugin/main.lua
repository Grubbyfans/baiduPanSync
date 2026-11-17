--[[--
BaiduPanSync plugin entry point — Stage B.

Stage B adds:
- full-content SHA-256 identity (`bookId`) with cache, progress and cancel;
- cloud progress JSON (schemaVersion=1) with writeId/deviceId/revision;
- backendId identity + backendId+bookId baselines + conflict classification;
- a local task state machine used for export/import;
- manual JSON exchange between devices (no network backend).

WebDAV/Baidu adapters, cloud libraries and remote conflict handling remain for
later stages.
]]

local DataStorage = require("datastorage")
local Device = require("device")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local _ = require("gettext")

local BookIdentity = require("modules/book_identity")
local ConfigStore = require("modules/config_store")
local ExportStore = require("modules/export_store")
local LocalStore = require("modules/storage")
local ProgressService = require("modules/progress")
local SyncEngine = require("modules/sync_engine")
local SyncState = require("modules/sync_state")
local Dialog = require("ui/progress_dialog")
local Menu = require("ui/menu")

local T = ffiUtil.template
local VERSION = "0.2.0"

local BaiduPanSync = WidgetContainer:extend{
    name = "baidupansync",
    is_doc_only = true,
    version = VERSION,
}

function BaiduPanSync:init()
    self.settings_dir = DataStorage:getSettingsDir() .. "/baidupansync"
    self.exports_dir = self.settings_dir .. "/exports"
    self.store = LocalStore:new{ dir = self.settings_dir }
    self.exports = ExportStore:new{ dir = self.exports_dir }
    self.config = ConfigStore:new{ dir = self.settings_dir }
    self.state = SyncState:new{ dir = self.settings_dir }
    self.identity = BookIdentity:new{ dir = self.settings_dir }
    self.progress = ProgressService:new{
        reader_ui = self.ui,
        store = self.store,
        event = Event,
    }
    self.engine = SyncEngine:new{
        identity = self.identity,
        progress = self.progress,
        exports = self.exports,
        state = self.state,
        config = self.config,
        device_label = Device.model or "koreader",
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

-- Builds hash UI callbacks. The progress dialog only appears on a cache miss;
-- cache hits complete synchronously without any dialog.
function BaiduPanSync:_hash_opts()
    local hash_ui
    return {
        on_hash_start = function(total)
            hash_ui = Dialog.start_hash_progress(total)
        end,
        on_hash_finish = function()
            if hash_ui then
                hash_ui:close()
                hash_ui = nil
            end
        end,
        on_progress = function(done)
            if hash_ui then hash_ui:report(done) end
        end,
        is_cancelled = function()
            return hash_ui ~= nil and hash_ui:is_cancelled()
        end,
        schedule = function(callback)
            UIManager:scheduleIn(0, callback)
        end,
    }
end

function BaiduPanSync:onExportProgress()
    local context, err = self.progress:capture()
    if not context then return Dialog.error(err) end
    self.engine:export_current(context, self:_hash_opts(), function(export_err, result)
        if export_err then
            if export_err.code == "CANCELLED" then
                return Dialog.info(_("已取消。"))
            end
            local extra
            if result and result.path then
                extra = T(_("导出文件已写入：%1"), result.path)
            end
            return Dialog.error(export_err, extra)
        end
        local record = result.record
        Dialog.info(T(_("已导出阅读进度：%1\n内容摘要：sha256:%2\n修订：%3\n文件：%4"),
            Dialog.percent_text(record.progress.percent),
            Dialog.short_hash(record.book.contentSha256),
            result.revision,
            result.path))
    end)
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
        if not entry.valid then return Dialog.error(entry.error) end
        local opts = self:_hash_opts()
        opts.confirm = function(info, decide)
            Dialog.confirm_import(info.record, info,
                function() decide(true) end,
                function() decide(false) end)
        end
        self.engine:import_from_file(entry.path, context, opts, function(import_err, result)
            if import_err then
                if import_err.code == "CANCELLED" then
                    return Dialog.info(_("已取消。"))
                end
                local extra
                if result and result.applied then
                    extra = _("阅读位置已恢复，但本地基线未更新，下次操作会重新核对。")
                end
                return Dialog.error(import_err, extra)
            end
            Dialog.info(T(_("已恢复到导入位置：%1\n记录 revision：%2\n可使用“撤销上次进度恢复”返回。"),
                Dialog.percent_text(result.record.progress.percent),
                result.record.sync.revision))
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
