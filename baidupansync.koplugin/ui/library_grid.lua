-- Native full-screen shelf: fixed cover slots, bounded captions and page nav.
local InputContainer=require('ui/widget/container/inputcontainer')
local Center=require('ui/widget/container/centercontainer')
local Frame=require('ui/widget/container/framecontainer')
local Vertical=require('ui/widget/verticalgroup')
local Horizontal=require('ui/widget/horizontalgroup')
local VSpan=require('ui/widget/verticalspan')
local HSpan=require('ui/widget/horizontalspan')
local Text=require('ui/widget/textboxwidget')
local Image=require('ui/widget/imagewidget')
local Title=require('ui/widget/titlebar')
local ButtonTable=require('ui/widget/buttontable')
local Buttons=require('ui/widget/buttondialog')
local Input=require('ui/widget/inputdialog')
local Geom=require('ui/geometry')
local GestureRange=require('ui/gesturerange')
local Font=require('ui/font')
local Screen=require('device').screen
local UI=require('ui/uimanager')
local BB=require('ffi/blitbuffer')
local Cover=require('modules/book_cover')
local Meta=require('modules/book_metadata')
local Issues=require('modules/library_issues')
local _=require('gettext')
local Grid=InputContainer:extend{covers_fullscreen=true,dithered=true}

function Grid.layout(width,height,header,footer)
    local cols,rows=3,3
    if width>height then cols,rows=4,2 end
    local gap=math.max(6,math.floor(width/80))
    return {cols=cols,rows=rows,count=cols*rows,gap=gap,
        cell_w=math.floor((width-gap*(cols+1))/cols),
        cell_h=math.floor((height-header-footer-gap*(rows+1))/rows)}
end

function Grid:init()
    self.state=self.state or {query='',order='name'}
    self.page=self.page or 1
    self.dimen=Geom:new{x=0,y=0,w=Screen:getWidth(),h=Screen:getHeight()}
    self.key_events={Close={{'Back'}}}
    self.ges_events={Swipe={GestureRange:new{ges='swipe',range=self.dimen}}}
    self:build()
end

function Grid:close()
    UI:close(self)
    return true
end
Grid.onClose=Grid.close
function Grid:onCloseWidget()
    if self.closed then return end
    self.closed=true
    self:free();self[1]=nil
    if self.on_close then self.on_close(self) end
end
function Grid:onSwipe(_,gesture)
    if gesture.direction=='west' then self:goToPage(self.page+1)
    elseif gesture.direction=='east' then self:goToPage(self.page-1) end
    return true
end

function Grid:goToPage(page)
    if self.closed then return end
    self.page=math.max(1,math.min(page,self.pages))
    self:rebuild()
end
function Grid:rebuild(skip_cover_fetch)
    if self.closed then return end
    if self[1] then self[1]:free();self[1]=nil end
    self.skip_cover_fetch=skip_cover_fetch
    self:build()
    self.skip_cover_fetch=nil
    UI:setDirty(self,'ui',nil,true)
end
function Grid:updateResult(result)
    if self.closed then return end
    self.result=result;self:rebuild()
end
function Grid:unpublished()
    return self:pending()
end
function Grid:pendingDetails(item)
    local dialog,buttons=nil,{}
    local function action(text,fn,entry)
        if fn then buttons[#buttons+1]={{text=text,callback=function()
            UI:close(dialog);if not self.closed then fn(entry)end
        end}} end
    end
    if item.repair then action('校验并补全发布',self.on_repair,item.repair)end
    if item.cleanup then action(item.repair and '删除未发布 EPUB' or '清理损坏的发布记录',self.on_cleanup,item.cleanup)end
    if item.entry then action('删除剩余云端文件与进度',self.on_delete,item.entry)end
    buttons[#buttons+1]={{text='返回待处理列表',callback=function()UI:close(dialog);if not self.closed then self:pending()end end}}
    dialog=Buttons:new{title=item.title..'\n'..item.path..'\n\n原因：'..item.reason,buttons=buttons}
    UI:show(dialog)
    return dialog
end
function Grid:pending()
    local buttons,dialog={},nil
    for _,item in ipairs(Issues.collect(self.result)) do
        local selected=item
        buttons[#buttons+1]={{text=item.title,
            callback=function()
                UI:close(dialog)
                if not self.closed then self:pendingDetails(selected) end
            end}}
    end
    buttons[#buttons+1]={{text='返回书库',callback=function()UI:close(dialog)end}}
    dialog=Buttons:new{title='待处理书籍\n选择条目查看原因，再决定修复或清理。',buttons=buttons,rows_per_page=6}
    UI:show(dialog)
    return dialog
end
function Grid:onSetDimensions()
    self.dimen.w=Screen:getWidth();self.dimen.h=Screen:getHeight()
    self:rebuild()
    return true
end

function Grid:search()
    local input
    local function apply(query)
        UI:close(input)
        if self.closed then return end
        self.state.query=query;self.page=1;self:rebuild()
    end
    input=Input:new{title=_('搜索云端书库'),input=self.state.query or '',
        input_hint=_('输入中文书名或文件名'),buttons={{
            {text=_('取消'),callback=function()UI:close(input)end},
            {text=_('清除'),callback=function()apply('')end},
            {text=_('搜索'),callback=function()apply(input:getInputText())end},
        }}}
    UI:show(input);input:onShowKeyboard()
end

function Grid:options()
    local dialog
    local pending_count=#Issues.collect(self.result)
    dialog=Buttons:new{title=_('书库选项'),buttons={
        {{text=_('按书名排序'),callback=function()
            UI:close(dialog);self.state.order='name';self.page=1;self:rebuild()
        end}},
        {{text=_('按文件大小排序'),callback=function()
            UI:close(dialog);self.state.order='size';self.page=1;self:rebuild()
        end}},
        {{text=_('主动更新书库'),enabled=self.on_refresh~=nil,callback=function()
            UI:close(dialog);if not self.closed and self.on_refresh then self.on_refresh() end
        end}},
        {{text=string.format('待处理书籍（%d）',pending_count),
            enabled=pending_count>0,callback=function()
                UI:close(dialog);if not self.closed then self:pending() end
            end}},
        {{text=_('书库信息'),callback=function()
            UI:close(dialog)
            local lines={'后端：'..(self.result.backend_label or self.result.backend),'服务：'..self.result.backend,'书籍：'..#self.result.entries,
                '异常记录：'..#self.result.issues}
            if self.result.updated_at then lines[#lines+1]='最近刷新：'..os.date('%Y-%m-%d %H:%M',self.result.updated_at) end
            if self.result.cached then lines[#lines+1]='当前显示本机缓存；每天首次进入或主动更新时获取书库列表。' end
            if self.result.refresh_error then lines[#lines+1]='刷新失败：'..self.result.refresh_error end
            for _,issue in ipairs(self.result.issues) do lines[#lines+1]=issue.path or '未知位置' end
            require('ui/progress_dialog').info(table.concat(lines,'\n'))
        end}},
        {{text=_('关闭'),callback=function()UI:close(dialog)end}},
    }}
    UI:show(dialog)
end

function Grid:select(entry)
    if not self.closed then return self:details(entry) end
    return true
end
function Grid:details(entry)
    local dialog
    local r=entry.record
    dialog=Buttons:new{title=self.title_for(r)..'\n\n文件：'..Meta.filename(r)..
        string.format('\n大小：%.2f MiB\n版本：%s',r.size/1048576,r.bookId:sub(1,12))..
        (entry.incomplete and '\n云端 EPUB 缺失或大小不符。可删除剩余记录，或重新上传原书恢复。' or ''),buttons={
        {{text=_('下载书籍'),enabled=not entry.incomplete and self.on_download~=nil,callback=function()
            UI:close(dialog)
            if not self.closed and not entry.incomplete and self.on_download then self.on_download(entry) end
        end}},
        {{text=_('删除云端书籍'),enabled=self.on_delete~=nil,callback=function()
            UI:close(dialog)
            if not self.closed and self.on_delete then self.on_delete(entry) end
        end}},
        {{text=_('返回书库'),callback=function()UI:close(dialog)end}},
    }}
    UI:show(dialog)
    return true
end

function Grid:cell(entry,layout)
    local w,h=layout.cell_w,layout.cell_h
    local fontsize=math.max(12,math.floor(self.dimen.w/48))
    local caption_h=math.ceil(fontsize*3.2)
    local cover_h=math.max(20,h-caption_h-layout.gap)
    local cover_w=math.max(20,math.min(w-4,math.floor(cover_h*0.72)))
    local title=self.title_for(entry.record)
    if entry.incomplete then title='[待处理] '..title end
    local cover
    local ok,bb=pcall(Cover.render,entry.coverPng or entry.record.coverPng)
    if ok and bb then
        local scale=math.min(cover_w/bb:getWidth(),cover_h/bb:getHeight())
        cover=Image:new{image=bb,scale_factor=scale}
    else
        cover=Frame:new{width=cover_w,height=cover_h,padding=0,margin=0,bordersize=1,
            background=BB.COLOR_LIGHT_GRAY,
            Center:new{dimen=Geom:new{w=cover_w-2,h=cover_h-2},
                Text:new{text=title,face=Font:getFace('cfont',fontsize+2),alignment='center',
                    width=cover_w-16,height=cover_h-16,height_overflow_show_ellipsis=true}}}
    end
    local content=Vertical:new{align='center',
        Center:new{dimen=Geom:new{w=w,h=cover_h},cover},
        VSpan:new{width=layout.gap},
        Center:new{dimen=Geom:new{w=w,h=caption_h},
            Text:new{text=title,face=Font:getFace('cfont',fontsize),width=w-4,height=caption_h,
                alignment='center',height_overflow_show_ellipsis=true}},
    }
    local cell=InputContainer:new{dimen=Geom:new{w=w,h=h},content}
    cell.ges_events={
        Select={GestureRange:new{ges='tap',range=function()return cell.dimen end}},
        Details={GestureRange:new{ges='hold',range=function()return cell.dimen end}},
    }
    cell.onSelect=function()return self:select(entry)end
    cell.onDetails=function()return self:details(entry)end
    return cell
end

function Grid:build()
    if not self.skip_cover_fetch and self.result.load_covers then
        local result=self.result
        UI:scheduleIn(0,function()
            if not self.closed and self.result==result then result.load_covers(self)end
        end)
    end
    local w,h=self.dimen.w,self.dimen.h
    local pending_count=#Issues.collect(self.result)
    local caption=self.result.refreshing and '云端书库 · 缓存刷新中' or self.result.cached and '云端书库 · 本机缓存' or '云端书库'
    local title=Title:new{width=w,fullscreen=true,align='center',title=caption,
        subtitle=self.result.backend_label or self.result.backend,
        left_icon='appbar.search',left_icon_tap_callback=function()self:search()end,
        close_callback=function()self:close()end}
    local toolbar_buttons={{
        {text=pending_count>0 and string.format('待处理 · %d',pending_count) or _('排序 / 管理'),
            callback=function()if pending_count>0 then self:pending()else self:options()end end},
        {text=self.state.query~='' and _('清除搜索') or _('搜索书籍'),callback=function()
            if self.state.query and self.state.query~='' then
                self.state.query='';self.page=1;self:rebuild()
            else self:search() end
        end},
    }}
    if self.on_refresh then
        toolbar_buttons[1][#toolbar_buttons[1]+1]={text=_('主动更新书库'),callback=function()if not self.closed then self.on_refresh()end end}
    end
    if self.on_switch_backend then
        toolbar_buttons[1][#toolbar_buttons[1]+1]={text=_('切换后端'),
            callback=function()if not self.closed then self.on_switch_backend()end end}
    end
    self.toolbar_buttons=toolbar_buttons
    local toolbar=ButtonTable:new{width=w,buttons=toolbar_buttons}
    self.entries=self.filter(self.result,self.state)
    local header=title:getSize().h+toolbar:getSize().h
    -- Navigation has a stable height; only its page label changes.
    local footer=ButtonTable:new{width=w,buttons={{
        {text='|‹',callback=function()self:goToPage(1)end},
        {text='‹',callback=function()self:goToPage(self.page-1)end},
        {text='1 / 1',callback=function()end},
        {text='›',callback=function()self:goToPage(self.page+1)end},
        {text='›|',callback=function()self:goToPage(self.pages)end},
    }}}
    local layout=Grid.layout(w,h,header,footer:getSize().h)
    self.layout_info=layout
    self.pages=math.max(1,math.ceil(#self.entries/layout.count))
    self.page=math.max(1,math.min(self.page,self.pages))
    -- Rebuild the footer label via a fresh table so button geometry is valid.
    footer:free()
    self.nav_buttons={{
        {text='|‹',enabled=self.page>1,callback=function()self:goToPage(1)end},
        {text='‹',enabled=self.page>1,callback=function()self:goToPage(self.page-1)end},
        {text=string.format('%d / %d',self.page,self.pages),callback=function()self:options()end},
        {text='›',enabled=self.page<self.pages,callback=function()self:goToPage(self.page+1)end},
        {text='›|',enabled=self.page<self.pages,callback=function()self:goToPage(self.pages)end},
    }}
    footer=ButtonTable:new{width=w,buttons=self.nav_buttons}
    self.visible_entries={}
    local body=Vertical:new{align='left',VSpan:new{width=layout.gap}}
    for row=1,layout.rows do
        local line=Horizontal:new{align='top',HSpan:new{width=layout.gap}}
        for col=1,layout.cols do
            local i=(self.page-1)*layout.count+(row-1)*layout.cols+col
            local entry=self.entries[i]
            if entry then
                self.visible_entries[#self.visible_entries+1]=entry
                line[#line+1]=self:cell(entry,layout)
            else
                line[#line+1]=InputContainer:new{dimen=Geom:new{w=layout.cell_w,h=layout.cell_h}}
            end
            line[#line+1]=HSpan:new{width=layout.gap}
        end
        body[#body+1]=line;body[#body+1]=VSpan:new{width=layout.gap}
    end
    if #self.entries==0 then
        body:free()
        body=Center:new{dimen=Geom:new{w=w,h=h-header-footer:getSize().h},
            Text:new{width=math.floor(w*0.8),alignment='center',face=Font:getFace('cfont',20),
                text=#self.result.entries==0 and pending_count>0 and '发现待处理书籍\n点击“待处理”查看原因并修复或清理。'
                    or #self.result.entries==0 and _('书库为空\n在另一设备上传 EPUB 后即可浏览。')
                    or _('未找到匹配书籍\n请更换关键词或清除搜索。')}}
    end
    self[1]=Frame:new{width=w,height=h,padding=0,margin=0,bordersize=0,background=BB.COLOR_WHITE,
        Vertical:new{align='left',title,toolbar,body,footer}}
    title.show_parent=self
end
return Grid
