--[[--
Main-menu definition for Stage A.

Only local actions are exposed; cloud items from spec 6 are intentionally not
shown yet, so nothing in the menu can mislead users into thinking a backend is
available.
]]

local _ = require("gettext")

local Menu = {}

--- Builds the submenu registered by main.lua.
-- @tparam table plugin BaiduPanSync instance
function Menu.build(plugin)
    return {
        text = _("书籍与阅读进度同步"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("导出当前阅读进度"),
                callback = function() plugin:onExportProgress() end,
            },
            {
                text = _("导入阅读进度"),
                callback = function() plugin:onImportProgress() end,
                enabled_func = function() return plugin:isCurrentBookSupported() end,
            },
            {
                text = _("撤销上次进度恢复"),
                callback = function() plugin:onUndoRestore() end,
                enabled_func = function() return plugin:hasRestorePoint() end,
            },
        },
    }
end

return Menu
