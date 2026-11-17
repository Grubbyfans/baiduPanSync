package.path='baidupansync.koplugin/?.lua;'..package.path
package.loaded['libs/libkoreader-lfs']={}
local F=require('modules/lan_firewall')
local commands={}
local function execute(command)commands[#commands+1]=command;return 0 end
local none=assert(F.open{is_kindle=false,execute=function()error('non-Kindle must not touch firewall')end})
assert(none:close())
local h=assert(F.open{is_kindle=true,ip='192.168.0.117',port=52473,execute=execute})
assert(#commands==2 and commands[1]:find('iptables -I INPUT 1 -d 192.168.0.117/32 -p tcp --dport 52473',1,true))
assert(commands[2]:find('iptables -I OUTPUT 1 -s 192.168.0.117/32 -p tcp --sport 52473',1,true))
assert(h:close() and #commands==4 and commands[3]:find('iptables -D OUTPUT',1,true) and commands[4]:find('iptables -D INPUT',1,true))
assert(h:close() and #commands==4,'cleanup must remove only owned rules once')
commands={}
local failed,e=F.open{is_kindle=true,ip='192.168.0.117',port=52473,execute=function(cmd)
    commands[#commands+1]=cmd
    if cmd:find('-I OUTPUT',1,true)then return 256 end
    return 0
end}
assert(not failed and e.code=='NETWORK' and #commands==3 and commands[3]:find('-D INPUT',1,true))
assert(not F.open{is_kindle=true,ip='192.168.0.117;echo injected',port=52473,execute=execute})
assert(not F.open{is_kindle=true,ip='192.168.0.117',port='80;echo injected',execute=execute})
-- Lua 5.2+ returns true, "exit", 0 rather than LuaJIT's integer status.
assert(F.open{is_kindle=true,ip='192.168.0.117',port=52473,execute=function()return true,'exit',0 end}:close())
local Server=require('modules/baidu_auth_server')
for _,reason in ipairs({'cancelled','expired','network_changed','success','failed'})do
    local closed,released=0,0
    local now=100
    local listener={settimeout=function()end,bind=function()return true end,listen=function()return true end,
        getsockname=function()return '192.168.0.117',52473 end,accept=function()return nil end,close=function()closed=closed+1 end}
    local s=assert(Server.start{ip='192.168.0.117',app_key='fixture',on_code=function()end,
        random=function(n)return string.rep('a',n*2)end,socket={tcp=function()return listener end,gettime=function()return now end},
        firewall={open=function(o)
            assert(o.ip=='192.168.0.117' and o.port==52473)
            return {close=function()released=released+1;return true end}
        end}})
    if reason=='expired' then now=701;s:poll_once()
    elseif reason=='network_changed' then s.ip_check=function()return false end;s:poll_once()
    elseif reason=='success' or reason=='failed' then
        s:finish(reason=='failed' and {message='fixture failure'} or nil);now=106;s:poll_once()
    else s:stop(reason)end
    s:stop(reason);assert(closed==1 and released==1)
end
print('Kindle scoped firewall open/rollback/cleanup and authorization lifecycle regressions passed')
