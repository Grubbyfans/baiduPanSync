-- Kindle's INPUT/OUTPUT policy blocks arbitrary LAN server ports. Own only
-- two narrow rules for the already-bound interface/port; never change policy.
local E=require('modules/errors')
local M={}
local function success(run,command)
    local ok,a,_,c=pcall(run,command..' >/dev/null 2>&1')
    return ok and (a==0 or (a==true and (c==nil or c==0)))
end
function M.open(o)
    o=o or {}
    local kindle=o.is_kindle
    if kindle==nil then
        local ok,device=pcall(require,'device')
        kindle=ok and device.isKindle and device:isKindle() or false
    end
    if not kindle then return {close=function()return true end} end
    local ip=o.ip
    local port=tonumber(o.port)
    if type(ip)~='string' or not ip:match('^%d+%.%d+%.%d+%.%d+$')
        or not port or port%1~=0 or port<1 or port>65535 then
        return nil,E.new('INVALID_INPUT','临时授权服务的防火墙地址或端口无效')
    end
    local run=o.execute or os.execute
    local rules={
        {'INPUT',string.format('-d %s/32 -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT',ip,port)},
        {'OUTPUT',string.format('-s %s/32 -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT',ip,port)},
    }
    local owned={}
    local handle={}
    function handle:close()
        local clean=true
        for i=#owned,1,-1 do
            local rule=owned[i]
            if success(run,'iptables -D '..rule[1]..' '..rule[2]) then table.remove(owned,i)
            else clean=false end
        end
        return clean
    end
    for _,rule in ipairs(rules) do
        if not success(run,'iptables -I '..rule[1]..' 1 '..rule[2]) then
            handle:close()
            return nil,E.new('NETWORK','Kindle 无法临时放行授权端口，请检查 iptables 或 KOReader 运行权限；未启动扫码服务')
        end
        owned[#owned+1]=rule
    end
    return handle
end
return M
