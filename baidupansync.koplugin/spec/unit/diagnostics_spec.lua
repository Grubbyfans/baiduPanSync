describe('bounded local task diagnostics',function()
    local D,lfs,root
    local function rm(path)
        local st=lfs.symlinkattributes(path);if not st then return end
        if st.mode=='directory'then for n in lfs.dir(path)do if n~='.' and n~='..'then rm(path..'/'..n)end end;lfs.rmdir(path)
        else os.remove(path)end
    end
    setup(function()require('commonrequire');D=require('modules/diagnostics');lfs=require('libs/libkoreader-lfs')end)
    before_each(function()root=os.tmpname();os.remove(root);assert(lfs.mkdir(root))end)
    after_each(function()rm(root)end)
    it('counts transport attempts, caches and stage durations without retaining URLs or errors',function()
        local now=0;local d=D.new{version='test',operation='upload_book',backend='webdav',clock=function()return now end}
        d:stage('reading_remote');d:cache('library',true)
        D.observe(d,function(req,cb)now=0.5;cb(nil,{status=200,body='private book data'})end,
            {url='https://secret.example/?access_token=TOPSECRET'},function()end)
        d:stage('writing');d:cache('download_link',false)
        D.observe(d,function(req,cb)now=1;cb({message='secret error with token'},nil)end,{},function()end)
        local v=d:finish('NETWORK')
        assert.is_equal(2,v.request_count);assert.is_equal(1,v.request_errors);assert.is_equal(1,v.seconds)
        assert.is_equal(0.5,v.stages[1].seconds);assert.is_equal(1,v.stages[1].requests)
        assert.is_equal(1,v.cache_hits.library);assert.is_equal(1,v.cache_misses.download_link)
        assert(D.save(root,v))
        local text=D.format(assert(D.read(root)))
        for _,secret in ipairs({'TOPSECRET','secret.example','private book data','secret error'})do assert.is_nil(text:find(secret,1,true))end
        assert.is_equal(v,d:finish('success'));assert.is_equal('NETWORK',v.result)
    end)
    it('retains only 20 summaries and preserves corrupt files',function()
        for i=1,22 do local d=D.new{operation=tostring(i)};d:stage('preparing');assert(D.save(root,d:finish()))end
        local rows=assert(D.read(root));assert.is_equal(20,#rows);assert.is_equal('3',rows[1].operation)
        local f=assert(io.open(root..'/diagnostics.json','wb'));f:write('{');f:close()
        local ok,e=D.save(root,D.new():finish());assert.is_nil(ok);assert.is_truthy(e)
        f=assert(io.open(root..'/diagnostics.json','rb'));assert.is_equal('{',f:read('*a'));f:close()
    end)
    it('counts each WebDAV HTTP request exactly once',function()
        local d=D.new{operation='list'}
        local backend=assert(require('modules/webdav'):new{root_url='http://test/sync/',username='u',password='p',
            transport=function(req,cb)cb(nil,{status=200,body='{}'})end})
        backend.operation_opts={diagnostics=d}
        backend:download('library.json',function(e,raw)assert.is_nil(e);assert.is_equal('{}',raw)end)
        assert.is_equal(1,d:finish().request_count)
    end)
    it('shows the diagnostics action in library options',function()
        local UI=require('ui/uimanager');local called=0
        local grid=require('ui/cloud_dialog').library({entries={},issues={},backend='fixture',on_diagnostics=function()called=called+1 end},function()end)
        grid:options();local dialog=UI._window_stack[#UI._window_stack].widget
        local button
        for _,row in ipairs(dialog.buttons)do if row[1].text=='最近任务诊断'then button=row[1]end end
        assert.is_truthy(button);button.callback();assert.is_equal(1,called);UI:close(grid)
    end)
end)
