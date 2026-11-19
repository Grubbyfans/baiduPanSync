-- One task-owned dialog across hashing, network requests and publication.
local Progress=require('ui/widget/progressbardialog')
local Frame=require('ui/widget/container/framecontainer')
local Vertical=require('ui/widget/verticalgroup')
local Text=require('ui/widget/textboxwidget')
local Label=require('ui/widget/textwidget')
local Font=require('ui/font')
local Bar=require('ui/widget/progresswidget')
local UI=require('ui/uimanager')
local Screen=require('device').screen
local BB=require('ffi/blitbuffer')
local M={};M.__index=M
local stages={
    upload_book={'准备书籍','读取书库列表','上传 EPUB','确认提交结果','发布书库列表'},
    download_book={'检查云端书籍','检查本机同名书籍','下载 EPUB','检查文件大小','安装到本机'},
    repair_book={'检查未发布文件','回读云端 EPUB','校验整书内容','补全发布记录'},
}
local titles={upload_book='上传书籍',download_book='下载书籍',repair_book='修复书库发布'}
function M.new(kind,backend)
    local self=setmetatable({kind=kind,backend=backend,stages=assert(stages[kind]),stage=1,
        detail='准备任务',count=0,visible=false,closed=false,cancelled=false},M)
    self.dialog=Progress:new{title=titles[kind],progress_max=1,refresh_time_seconds=0.5,
        dismiss_text='停止当前任务？写入若已发出，结果可能未知，需要重新查询。',
        dismiss_callback=function()
            self.visible=false;self.cancelled=true
            if self.transport_cancel then self.transport_cancel()end
        end}
    self.dismiss=self.dialog.dismiss_callback
    return self
end
function M:render()
    if self.closed or self.cancelled or self.paused then return end
    local width=Screen:getWidth()-Screen:scaleBySize(80)
    local lines={}
    for i,name in ipairs(self.stages) do
        lines[#lines+1]=(self.completed or i<self.stage) and ('✓ '..name)
            or (i==self.stage and ('▶ '..name) or ('· '..name))
    end
    if self.dialog[1] then self.dialog[1]:free()end
    self.dialog.progress_bar=Bar:new{width=width,height=Screen:scaleBySize(18),percentage=0,fillcolor=BB.COLOR_BLACK}
    self.dialog.progress_bar_visible=true
    self.dialog.progress_max=self.total or 1
    self.counter=Label:new{text=self:counter_text(),face=Font:getFace('smallffont'),max_width=width}
    self.dialog[1]=Frame:new{padding=Screen:scaleBySize(12),bordersize=2,radius=8,background=BB.COLOR_WHITE,
        Vertical:new{align='left',
            Label:new{text=titles[self.kind],face=Font:getFace('ffont'),bold=true,max_width=width},
            Label:new{text=self.backend,face=Font:getFace('smallffont'),max_width=width},
            Text:new{text=table.concat(lines,'\n'),width=width,face=Font:getFace('cfont',20)},
            Label:new{text=self.detail,face=Font:getFace('smallffont'),max_width=width},
            self.counter,self.dialog.progress_bar,
        }}
    self.dialog.dismiss_callback=self.dismiss
    if not self.visible then self.visible=true;self.dialog:show()end
    self.dialog:reportProgress(self.count)
    UI:setDirty(self.dialog,'ui')
end
function M:counter_text()
    if not self.total or self.total<=0 then return '当前阶段：等待处理完成；整项任务尚未完成' end
    return string.format('当前阶段：%.2f / %.2f MiB（%.0f%%）',self.count/1048576,self.total/1048576,
        math.min(100,self.count/self.total*100))
end
function M:set_stage(stage,detail)
    if self.closed or self.cancelled then return end
    if stage>self.stage then self.stage=stage;self.count=0;self.total=nil end
    self.detail=detail or self.stages[self.stage]
    self:render()
end
function M:state(state)
    self.current_state=state
    if state=='awaiting_confirm' then self:hide();self.paused=true;return end
    self.paused=false
    local maps={upload_book={reading_remote=2,rechecking=2,writing=3,verifying=4,committing_local=5},
        download_book={reading_remote=1,rechecking=2,downloading=3,validating=4,committing_local=5},
        repair_book={reading_remote=1,rechecking=1,writing=2,verifying=2,committing_local=4}}
    if state=='done' then self.completed=true;return end
    if state=='failed' or state=='cancelled' or state=='uncertain' then return end
    self:set_stage(maps[self.kind][state] or self.stage)
end
function M:phase(name)
    local stage=self.stage
    if name:find('发布',1,true) then stage=#self.stages
    elseif name:find('核对整书',1,true) then stage=self.kind=='repair_book' and 3 or 4 end
    self:set_stage(stage,name)
end
function M:hash_start(total)
    self.detail=self.stage==3 and self.kind=='upload_book' and '计算上传分片摘要' or '计算上传分片 MD5'
    self.total=total;self.count=0;self:render()
end
function M:report(count,total)
    if self.closed or self.cancelled or self.paused then return end
    if total and total>0 then self.total=total end
    self.count=math.max(0,math.min(count or 0,self.total or 0))
    if self.counter then self.counter:setText(self:counter_text())end
    if self.visible then self.dialog.progress_max=self.total or 1;self.dialog:reportProgress(self.count)end
end
function M:attach(cancel,req)
    self.transport_cancel=cancel
    local detail=req.upload_path and '正在上传 EPUB' or req.download_path and '正在回读 / 下载 EPUB' or '正在访问云端'
    local redraw=detail~=self.detail or req.upload_path or req.download_path
    if req.upload_path or req.download_path then self.count=0;self.total=nil end
    self.detail=detail
    if redraw then self:render()end
end
function M:detach(cancel)
    if self.transport_cancel==cancel then self.transport_cancel=nil end
end
function M:hide()
    if not self.visible then return end
    self.visible=false;self.dialog.dismiss_callback=nil;self.dialog:close()
end
function M:close()
    if self.closed then return end
    self.closed=true;self.transport_cancel=nil;self.dialog.dismiss_callback=nil;self:hide()
    if self.dialog[1] then self.dialog[1]:free();self.dialog[1]=nil end
end
function M:is_cancelled()return self.cancelled or self.closed end
return M
