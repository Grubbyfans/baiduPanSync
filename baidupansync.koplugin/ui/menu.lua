-- Manual cloud operations, local JSON exchange and backend configuration.


local _ = require("gettext")

local Menu = {}

--- Builds the submenu registered by main.lua.
-- @tparam table plugin BaiduPanSync instance
function Menu.actions(plugin)
    return {
            { text = _("上传当前阅读进度到云端"), callback = function() plugin:onUploadCloudProgress() end,
                enabled_func = function() return plugin:isCurrentBookSupported() end },
            { text = _("查询云端阅读进度"), callback = function() plugin:onQueryCloudProgress() end,
                enabled_func = function() return plugin:isCurrentBookSupported() end },
            { text = _("下载并应用云端阅读进度"), callback = function() plugin:onDownloadCloudProgress() end,
                enabled_func = function() return plugin:isCurrentBookSupported() end },
            { text = _("上传当前 EPUB 书籍"), callback = function() plugin:onUploadBook() end,
                enabled_func = function() return plugin:isCurrentBookSupported() end },
            { text = _("云端书库 / 下载书籍"), callback = function() plugin:onCloudLibrary() end },

            {
                text = _("本地导出阅读进度 JSON"),
                enabled_func = function() return plugin:isCurrentBookSupported() end,
                callback = function() plugin:onExportProgress() end,
            },
            {
                text = _("本地导入阅读进度 JSON"),
                callback = function() plugin:onImportProgress() end,
                enabled_func = function() return plugin:isCurrentBookSupported() end,
            },
            {
                text = _("撤销上次进度恢复"),
                callback = function() plugin:onUndoRestore() end,
                enabled_func = function() return plugin:hasRestorePoint() end,
            },
            {
                text = _("WebDAV 配置"),
                callback = function() require("ui/backend_dialog").configure(plugin) end,
            },
            {
                text = _("WebDAV 连接与测试文件验证"),
                callback = function() require("ui/backend_dialog").probe(plugin) end,
            },
    }
end

function Menu.build(plugin)
    return {
        text = _("书籍与阅读进度同步"),
        sorting_hint = "more_tools",
        keep_menu_open = true,
        callback = function(touch_menu)
            -- Close the system menu first, then open our own persistent page.
            if touch_menu and touch_menu.closeMenu then touch_menu:closeMenu() end
            plugin:showHome()
        end,
    }
end

return Menu
