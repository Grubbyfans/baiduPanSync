describe('visible backend identity',function()
    local Label
    setup(function()require('commonrequire');Label=require('ui/backend_label')end)
    it('identifies the DAV host and directory without credentials or query strings',function()
        assert.is_equal('WebDAV · example.com:8443/books/',Label.for_backend{
            root='https://user:SECRET@example.com:8443/books/?access_token=SECRET#fragment'})
        assert.is_equal('WebDAV · [::1]:8080/sync/',Label.for_backend{root='http://[::1]:8080/sync/'})
    end)
    it('names Baidu accounts and provides clear missing-account fallbacks',function()
        assert.is_equal('百度网盘 · 测试账户',Label.for_backend{kind='baidu',profile={account_name='测试账户',access_token='SECRET'}})
        assert.is_equal('百度网盘 · 1234',Label.for_backend{kind='baidu',profile={account_name='',user_id='1234'}})
        assert.is_equal('百度网盘 · 待授权',Label.for_backend{kind='baidu'})
    end)
    it('uses the selected backend instead of another configured backend',function()
        local plugin={active_backend='baidu',dav_adapter={root='http://dav.example/sync/'},
            baidu_store={load=function()return {account_name='我的账户'}end}}
        assert.is_equal('百度网盘 · 我的账户',Label.for_plugin(plugin))
        plugin.active_backend='webdav'
        assert.is_equal('WebDAV · dav.example/sync/',Label.for_plugin(plugin))
    end)
end)
