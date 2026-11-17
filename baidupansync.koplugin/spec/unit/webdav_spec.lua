describe('WebDAV C1 adapter',function()
    local DAV,requests,reply,adapter
    setup(function() require('commonrequire'); DAV=require('modules/webdav') end)
    before_each(function()
        requests={};reply={status=200,headers={},body=''}
        adapter=assert(DAV:new{root_url='http://localhost/sync/',username='u',password='p',
            transport=function(req,done)
                requests[#requests+1]=req
                if req.method=='PROPFIND' and req.headers.Depth=='0' and reply.status==200 then
                    local body='<d:multistatus xmlns:d="DAV:"><d:response><d:href>/sync/a</d:href><d:propstat><d:prop>'..
                        '<d:resourcetype/><d:getetag>'..(reply.headers.etag or '')..'</d:getetag></d:prop>'..
                        '<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>'
                    return done(nil,{status=207,headers={},body=body})
                end
                done(nil,reply)
            end})
    end)
    it('rejects path traversal and encoded separator input before HTTP',function()
        for _,path in ipairs({'../secret','/etc','x/%2e%2e/y','a\\b','a?b','a//b'}) do
            adapter:stat(path,function(e) assert.is_equal('INVALID_INPUT',e.code) end)
        end
        assert.is_equal(0,#requests)
    end)
    it('preserves weak ETags and rejects them as conditions',function()
        reply.headers.etag='W/"abc"'
        adapter:stat('a',function(e,s) assert.is_nil(e);assert.is_true(s.weak_etag);assert.is_equal('W/"abc"',s.etag) end)
        adapter.conditional_verified=true
        adapter:uploadSmallJson('a','{}',{etag='W/"abc"'},function(e) assert.is_equal('INVALID_INPUT',e.code) end)
        assert.is_equal(1,#requests)
    end)
    it('never silently drops conditions on unqualified services',function()
        adapter:uploadSmallJson('a','{}',{absent=true},function(e) assert.is_equal('UNSUPPORTED',e.code) end)
        assert.is_equal(0,#requests)
        adapter.conditional_verified=true
        adapter:uploadSmallJson('a','{}',{absent=true},function(e) assert.is_nil(e) end)
        assert.is_equal('*',requests[1].headers['If-None-Match'])
    end)
    it('maps missing/auth/conflict and rejects all redirects',function()
        for code,expected in pairs({[404]='NOT_FOUND',[401]='AUTH',[403]='FORBIDDEN',[412]='CONFLICT',[302]='NETWORK',[307]='NETWORK'}) do
            reply.status=code
            adapter:stat('a',function(e) assert.is_equal(expected,e.code) end)
        end
        assert.is_equal(6,#requests)
    end)
    it('refuses cleanup of published data',function()
        adapter:delete('books/a.epub',nil,function(e) assert.is_equal('FORBIDDEN',e.code) end)
        assert.is_equal(0,#requests)
    end)
    it('fails closed for malformed XML, DTD and escaped root paths',function()
        reply.status=207
        for _,xml in ipairs({'<broken>', '<!DOCTYPE d><multistatus/>',
            '<d:multistatus><d:response><d:href>/other/a</d:href></d:response></d:multistatus>'}) do
            reply.body=xml
            adapter:list('',nil,function(e) assert.is_truthy(e) end)
        end
    end)
    it('rejects HTTPS without a usable CA file',function()
        local e=require('modules/dav_transport').perform{url='https://localhost/',cafile='/nonexistent/bps-ca.pem'}
        assert.is_equal('TLS',e.code)
    end)
    it('runs real HTTP probe when isolated server is supplied',function()
        local url=os.getenv('BPS_DAV_TEST_URL')
        if not url then pending('set BPS_DAV_TEST_URL for isolated HTTP integration');return end
        local transport=require('modules/dav_transport')
        local actual=assert(DAV:new{root_url=url,username='u',password='p',
            transport=function(req,done) done(transport.perform(req)) end})
        local calls=0
        require('modules/dav_probe').run(actual,function(e,r)
            calls=calls+1
            assert.is_nil(e)
            assert.is_true(r.conditional_create)
            assert.is_true(r.conditional_replace)
            assert.is_nil(r.cleanup_error)
        end)
        assert.is_equal(1,calls)
    end)
    it('rejects malformed attributes and foreign DAV namespaces',function()
        reply.status=207
        for _,xml in ipairs({
            '<d:multistatus xmlns:d="not-DAV"/>',
            '<d:multistatus xmlns:d="DAV:" broken=invalid/>',
        }) do
            reply.body=xml
            adapter:list('',nil,function(e) assert.is_equal('INVALID_INPUT',e.code) end)
        end
    end)
    it('reports interrupted writes as uncertain and reads as cancelled',function()
        local previous=package.loaded['ui/trapper']
        package.loaded['ui/trapper']={
            wrap=function(_,fn)fn()end,
            dismissableRunInSubprocess=function()return false end,
        }
        local results={}
        local ok,failure=pcall(function()
            for _,method in ipairs({'GET','PUT'}) do
                require('modules/dav_transport').request({method=method},function(e)results[method]=e end)
            end
        end)
        package.loaded['ui/trapper']=previous
        assert.is_true(ok,tostring(failure))
        assert.is_equal('CANCELLED',results.GET.code)
        assert.is_equal('UNCERTAIN',results.PUT.code)
        assert.is_equal('uncertain',results.PUT.outcome)
    end)

    it('decodes escaped ampersands in valid DAV filenames',function()
        reply.status=207
        reply.body='<d:multistatus xmlns:d="DAV:"><d:response><d:href>/sync/a&amp;b.json</d:href>'..
            '<d:propstat><d:prop><d:resourcetype/><d:getcontentlength>2</d:getcontentlength></d:prop>'..
            '<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>'
        adapter:list('',nil,function(e,r)
            assert.is_nil(e);assert.is_equal('a&b.json',r.entries[1].path)
        end)
    end)

    it('requires separately verified conditional deletion for publication withdrawal',function()
        local path='metadata/'..string.rep('a',64)..'.json'
        adapter.conditional_verified=true
        adapter:delete(path,{etag='"version"'},function(e)assert.is_equal('UNSUPPORTED',e.code)end)
        assert.is_equal(0,#requests)
        adapter.conditional_delete_verified=true
        adapter:delete(path,{etag='"version"'},function(e)assert.is_nil(e)end)
        assert.is_equal('"version"',requests[1].headers['If-Match'])
    end)

end)
