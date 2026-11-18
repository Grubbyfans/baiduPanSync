describe('LAN authorization address discovery',function()
    local Server,interfaces,closed
    local function socket_for(ip,connected)
        return {udp=function()return {
            settimeout=function()end,
            setpeername=function()return connected~=false end,
            getsockname=function()return ip,12345 end,
            close=function()closed=closed+1 end,
        }end}
    end
    setup(function()require('commonrequire');Server=require('modules/baidu_auth_server')end)
    before_each(function()interfaces=Server.interface_ips;closed=0 end)
    after_each(function()Server.interface_ips=interfaces end)
    it('keeps the existing private default-route behavior for readers',function()
        Server.interface_ips=function()error('must not enumerate on the fast path')end
        assert.is_equal('192.168.0.117',Server.detect_ip(socket_for('192.168.0.117')))
        assert.is_equal(1,closed)
    end)
    it('falls back to the LAN interface when a VPN owns the default route',function()
        Server.interface_ips=function()return {'192.168.10.192'}end
        assert.is_equal('192.168.10.192',Server.detect_ip(socket_for('28.0.0.1')))
        assert.is_equal(1,closed)
    end)
    it('works without a usable default route or UDP socket',function()
        Server.interface_ips=function()return {'10.0.0.2'}end
        assert.is_equal('10.0.0.2',Server.detect_ip(socket_for(nil,false)))
        assert.is_equal('10.0.0.2',Server.detect_ip({udp=function()return nil end}))
        assert.is_equal(1,closed)
    end)
    it('requires manual selection for ambiguous or unavailable interfaces',function()
        for _,values in ipairs({{}, {'10.0.0.2','192.168.1.2'}}) do
            Server.interface_ips=function()return values end
            assert.is_nil(Server.detect_ip(socket_for('28.0.0.1')))
        end
        Server.interface_ips=function()error('unsupported interface API')end
        assert.is_nil(Server.detect_ip(socket_for('28.0.0.1')))
    end)
    it('checks the selected LAN address without depending on the Internet route',function()
        Server.interface_ips=function()return {'192.168.10.192'}end
        assert.is_true(Server.has_ip('192.168.10.192',socket_for('28.0.0.1')))
        Server.interface_ips=function()return {}end
        assert.is_false(Server.has_ip('192.168.10.192',socket_for('28.0.0.1')))
    end)
    it('reads private addresses using the native platform sockaddr layout',function()
        local addresses=assert(Server.interface_ips())
        local seen={}
        for _,ip in ipairs(addresses) do
            assert.is_true(Server.private_ip(ip));assert.is_nil(seen[ip]);seen[ip]=true
        end
    end)
    it('starts and keeps a real LAN listener alive behind a nonprivate VPN route',function()
        local ip=os.getenv('BPS_AUTH_LAN_TEST_IP')
        if not ip then pending('requires explicit local LAN socket fixture address');return end
        local socket=require('socket')
        local addresses=assert(Server.interface_ips())
        assert.are.same({ip},addresses)
        local fake=socket_for('28.0.0.1')
        fake.tcp=socket.tcp;fake.gettime=socket.gettime
        local server=assert(Server.start{socket=fake,app_key='fixture',on_code=function()end})
        local ok,err=pcall(function()
            assert.is_equal(ip,server.ip)
            server:poll_once();assert.is_nil(server.closed)
            local client=assert(socket.tcp());client:settimeout(1)
            local connected=client:connect(server.ip,tonumber(server.authority:match(':(%d+)$')))
            client:close();assert.is_truthy(connected)
        end)
        server:stop('test_cleanup')
        assert.is_true(ok,tostring(err))
    end)
end)
