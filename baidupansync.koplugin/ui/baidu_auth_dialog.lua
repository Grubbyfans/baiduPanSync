local InputContainer=require('ui/widget/container/inputcontainer')
local Center=require('ui/widget/container/centercontainer')
local Frame=require('ui/widget/container/framecontainer')
local Vertical=require('ui/widget/verticalgroup')
local VSpan=require('ui/widget/verticalspan')
local Text=require('ui/widget/textboxwidget')
local Title=require('ui/widget/titlebar')
local ButtonTable=require('ui/widget/buttontable')
local Input=require('ui/widget/inputdialog')
local QR=require('ui/widget/qrwidget')
local Font=require('ui/font')
local Geom=require('ui/geometry')
local Screen=require('device').screen
local UI=require('ui/uimanager')
local BB=require('ffi/blitbuffer')
local Page=InputContainer:extend{covers_fullscreen=true}
function Page:init()
    local w,h=Screen:getWidth(),Screen:getHeight()
    self.dimen=Geom:new{x=0,y=0,w=w,h=h}
    self.key_events={Close={{'Back'}}}
    local function close()self:close()end
    local title=Title:new{width=w,title='百度网盘授权',close_callback=close}
    self.status=Text:new{text='等待手机提交 · 有效期 10 分钟',width=w-40,alignment='center',face=Font:getFace('cfont',18)}
    local help=Text:new{text='手机与阅读器连接同一 Wi-Fi\n扫码 → 前往百度授权 → 复制授权码 → 返回手机页面提交',
        width=w-40,alignment='center',face=Font:getFace('cfont',18)}
    local address=Text:new{text=self.session.url,width=w-40,alignment='center',face=Font:getFace('cfont',14)}
    local buttons=ButtonTable:new{width=w,buttons={
        {{text='在阅读器输入授权码',callback=function()self:manual()end}},
        {{text='取消授权',callback=close}},
    }}
    local fixed=title:getSize().h+help:getSize().h+self.status:getSize().h+address:getSize().h+buttons:getSize().h+72
    local size=math.max(60,math.floor(math.min(w*0.62,h-fixed)))
    local qr=QR:new{text=self.session.url,width=size,height=size}
    self[1]=Frame:new{width=w,height=h,padding=0,margin=0,bordersize=0,background=BB.COLOR_WHITE,
        Vertical:new{align='center',title,VSpan:new{width=20},
            help,VSpan:new{width=20},
            Center:new{dimen=Geom:new{w=w,h=size},qr},VSpan:new{width=16},self.status,
            address,VSpan:new{width=16},buttons,
        }}
end
function Page:update(seconds,state)
    if self.closed then return end
    local text=state=='waiting' and string.format('等待手机提交 · 剩余 %d:%02d',math.floor(seconds/60),seconds%60)
        or '正在校验授权并保存凭据…'
    if text~=self.last_text then self.last_text=text;self.status:setText(text);UI:setDirty(self,'ui') end
end
function Page:manual()
    local input
    input=Input:new{title='输入百度授权码',input='',buttons={{
        {text='取消',callback=function()UI:close(input)end},
        {text='提交',callback=function()
            local code=input:getInputText();UI:close(input)
            if not self.closed then self.on_code(code) end
        end},
    }}}
    UI:show(input);input:onShowKeyboard()
end
function Page:close()if not self.closed then UI:close(self) end;return true end
Page.onClose=Page.close
function Page:onCloseWidget()
    if self.closed then return end
    self.closed=true;self:free();self[1]=nil
    if not self.completed then self.on_cancel() end
end
function Page:onSuspend()self.on_cancel();self:close()end
function Page:onNetworkDisconnected()self.on_cancel('network_changed');self:close()end
return Page
