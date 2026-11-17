-- A full-screen native KOReader page. Selecting actions never closes it.
local Menu=require('ui/widget/menu')
local Actions=require('ui/menu')
local _=require('gettext')
local Home=Menu:extend{is_borderless=true,items_per_page=6}
local sections={
    progress={title=_('阅读进度'),hint=_('先查看云端进度，再选择上传或应用；应用后可撤销。'),
        actions={'query_progress','upload_progress','download_progress','undo'}},
    settings={title=_('连接设置'),hint=_('配置 WebDAV 或百度网盘，验证连接并选择当前后端。'),
        actions={'configure','probe','baidu','switch_backend'}},
}

function Home:openSection(section)
    self.section=section
    self:refresh(true)
end

function Home:items()
    local plugin=self.plugin
    local busy=plugin.dav_busy or plugin.undo_busy or plugin.baidu_busy
    local cloud_ready=plugin.dav_adapter
    if plugin.active_backend=='baidu' then cloud_ready=plugin.hasUsableBaidu and plugin:hasUsableBaidu() end
    local actions={}
    for _,item in ipairs(Actions.actions(plugin)) do
        local enabled=not busy and (not item.enabled_func or item.enabled_func())
        if item.requires_book_backend and not cloud_ready then enabled=false
        elseif item.requires_cloud and not item.requires_book_backend and not plugin.dav_adapter then enabled=false end
        if item.id=='undo' and not plugin:isCurrentBookSupported() then enabled=false end
        item.select_enabled=enabled and true or false
        item.dim=not enabled
        actions[item.id]=item
    end
    local profile=plugin.dav_profile
    actions.configure.text=profile and _('修改 WebDAV 配置') or _('配置 WebDAV')
    actions.probe.text=_('测试 WebDAV 连接')
    actions.switch_backend.text=plugin.active_backend=='baidu' and _('当前后端：百度网盘 ›') or _('当前后端：WebDAV ›')
    actions.library.text=_('云端书库 · 下载书籍')
    actions.upload_book.text=_('上传当前书籍')
    local items={}
    local section=sections[self.section]
    if section then
        items[1]={text=_('‹ 返回主页'),id='back',select_enabled=true,callback=function()self:openSection(nil)end}
        for _,id in ipairs(section.actions) do items[#items+1]=actions[id] end
    else
        items={actions.library,actions.upload_book}
        for _,id in ipairs({'progress','settings'}) do
            local target=id
            items[#items+1]={id=id,text=sections[id].title..' ›',select_enabled=true,
                callback=function()self:openSection(target)end}
        end
        if not cloud_ready then items[4].text=_('连接设置 · 请先配置 ›') end
    end
    return items
end

function Home:status()
    local book=self.plugin.ui and self.plugin.ui.document
    local name=book and book.file and book.file:match('([^/]+)$')
    local backend=self.plugin.dav_adapter and _('WebDAV 已配置') or _('请先配置 WebDAV')
    if self.plugin.dav_load_error then backend=_('WebDAV 配置需检查') end
    if self.plugin.active_backend=='baidu' then
        backend=self.plugin.hasUsableBaidu and self.plugin:hasUsableBaidu() and _('百度网盘已连接') or _('百度网盘授权 / 连接需检查')
    end
    local section=sections[self.section]
    return backend..' · '..(name and (_('当前书籍：')..name) or _('当前未打开书籍'))..
        (section and ('\n'..section.hint) or '')
end

function Home:init()
    self.title=_('书籍与阅读进度同步')
    self.subtitle=self:status()
    self.item_table=self:items()
    Menu.init(self)
end

function Home:refresh(reset)
    if self.closed then return end
    self.title=sections[self.section] and sections[self.section].title or _('书籍与阅读进度同步')
    local selected=reset and 1 or self.itemnumber or ((self.page-1)*self.perpage+1)
    self:switchItemTable(self.title,self:items(),selected,nil,self:status())
end

function Home:onClose()
    if self.section then self:openSection(nil);return true end
    return Menu.onClose(self)
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
