-- A full-screen native KOReader page. Selecting actions never closes it.
local Menu=require('ui/widget/menu')
local UI=require('ui/uimanager')
local Actions=require('ui/menu')
local _=require('gettext')
local Home=Menu:extend{is_borderless=true,items_per_page=10}

function Home:items()
    local plugin=self.plugin
    local busy=plugin.dav_busy or plugin.undo_busy or (plugin.engine and plugin.engine._active)
    local items=Actions.actions(plugin)
    for index,item in ipairs(items) do
        local enabled=not busy and (not item.enabled_func or item.enabled_func())
        if index<=5 and not plugin.dav_adapter then enabled=false end
        if index==8 and not plugin:isCurrentBookSupported() then enabled=false end
        item.select_enabled=enabled and true or false
        item.dim=not enabled
    end
    local profile=plugin.dav_profile
    items[9].text=profile and _('WebDAV 配置（已配置）') or _('WebDAV 配置（未配置）')
    return items
end

function Home:status()
    local book=self.plugin.ui and self.plugin.ui.document
    local name=book and book.file and book.file:match('([^/]+)$')
    local backend=self.plugin.dav_adapter and _('WebDAV 已配置') or _('请先配置 WebDAV')
    if self.plugin.dav_load_error then backend=_('WebDAV 配置需检查') end
    return backend..' · '..(name and (_('当前书籍：')..name) or _('当前未打开书籍'))
end

function Home:init()
    self.title=_('书籍与阅读进度同步')
    self.subtitle=self:status()
    self.item_table=self:items()
    Menu.init(self)
end

function Home:refresh()
    if self.closed then return end
    local selected=self.itemnumber or ((self.page-1)*self.perpage+1)
    self:switchItemTable(self.title,self:items(),selected,nil,self:status())
end

function Home:onMenuSelect(item)
    if self.closed then return true end
    -- Refresh the permission snapshot before dispatch (async tasks may have
    -- changed state since this row was drawn).
    local current=self:items()[item.idx]
    if not current or not current.select_enabled then return true end
    current.callback()
    self:refresh()
    return true
end

function Home:onCloseWidget()
    self.closed=true
    if self.plugin.home_page==self then self.plugin.home_page=nil end
    Menu.onCloseWidget(self)
end

function Home:onShowingReader()
    self.plugin:closeHome()
end
Home.onSetupShowReader=Home.onShowingReader
return Home
