describe('DAV independent TLS identity',function()
    local TLS
    setup(function()require('commonrequire');TLS=require('modules/dav_tls')end)
    local function cert(san)
        return {extensions=function()return {['2.5.29.17']=san}end}
    end
    it('requires SAN and never falls back to matching commonName',function()
        assert.is_false(TLS.matches(cert(nil),'localhost'))
        assert.is_false(TLS.matches(cert{dNSName={'other.invalid'}},'localhost'))
        assert.is_true(TLS.matches(cert{dNSName={'LOCALHOST'}},'localhost'))
    end)
    it('limits wildcard matching to one DNS label',function()
        local c=cert{dNSName={'*.example.com'}}
        assert.is_true(TLS.matches(c,'reader.example.com'))
        assert.is_false(TLS.matches(c,'a.reader.example.com'))
        assert.is_false(TLS.matches(c,'example.com'))
        assert.is_false(TLS.matches(cert{dNSName={'*.com'}},'example.com'))
    end)
    it('matches IPv4/IPv6 only against IP SAN',function()
        assert.is_false(TLS.matches(cert{dNSName={'127.0.0.1'}},'127.0.0.1'))
        assert.is_true(TLS.matches(cert{iPAddress={'127.0.0.1'}},'127.0.0.1'))
        assert.is_false(TLS.matches(cert{iPAddress={'127.0.0.2'}},'127.0.0.1'))
        assert.is_true(TLS.matches(cert{iPAddress={'0:0:0:0:0:0:0:1'}},'::1'))
    end)
    it('runs trusted, unknown-CA, expired, wrong-SAN and IP integration matrix',function()
        local config=os.getenv('BPS_TLS_TEST_CONFIG')
        if not config then pending('set BPS_TLS_TEST_CONFIG from isolated dav_tls_server.py');return end
        local v=require('json').decode(config)
        local transport=require('modules/dav_transport')
        local function request(port,host,ca)
            return transport.perform{url='https://'..host..':'..port..'/sync/no-file.json',
                method='GET',username='u',password='p',cafile=ca or v.cafile}
        end
        local e,r=request(v.valid,'localhost')
        assert.is_nil(e);assert.is_equal(404,r.status)
        e,r=request(v.valid,'127.0.0.1')
        assert.is_nil(e);assert.is_equal(404,r.status)
        e=request(v.wrong,'localhost') -- certificate CN matches but SAN does not
        assert.is_equal('TLS',e.code)
        e=request(v.wrong,'127.0.0.1')
        assert.is_equal('TLS',e.code)
        e=request(v.expired,'localhost')
        assert.is_equal('TLS',e.code)
        e=request(v.valid,'localhost','/nonexistent/ca.pem')
        assert.is_equal('TLS',e.code)
        e=request(v.valid,'localhost',v.othercafile)
        assert.is_equal('TLS',e.code)
        local base='https://localhost:'..v.valid
        e,r=transport.perform{url=base..'/__sni',method='GET',username='u',password='p',cafile=v.cafile}
        assert.is_nil(e);assert.is_equal('localhost',r.body)
        e,r=transport.perform{url=base..'/__redirect',method='GET',username='u',password='p',cafile=v.cafile}
        assert.is_nil(e);assert.is_equal(302,r.status)
        local dav=assert(require('modules/webdav'):new{root_url=base..'/sync/',username='u',password='p',cafile=v.cafile,
            transport=function(req,done)done(transport.perform(req))end})
        local completed=0
        require('modules/dav_probe').run(dav,function(probe_err,report)
            completed=completed+1
            assert.is_nil(probe_err);assert.is_true(report.conditional_replace)
        end)
        assert.is_equal(1,completed)
        -- System trust does not include our temporary private CA.
        e=transport.perform{url='https://localhost:'..v.valid..'/sync/no-file.json',method='GET',username='u',password='p'}
        assert.is_equal('TLS',e.code)
    end)
end)
