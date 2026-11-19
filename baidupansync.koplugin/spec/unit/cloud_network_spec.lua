describe('D/E/F real WebDAV transport',function()
    setup(function()require('commonrequire')end)
    it('streams a file larger than the old in-memory limit, publishes, downloads and synchronizes progress',function()
        local url=os.getenv('BPS_DAV_TEST_URL')
        if not url then pending('requires isolated WebDAV fixture');return end
        local A=require('modules/async')
        local DAV=require('modules/webdav')
        local Transport=require('modules/dav_transport')
        local Cloud=require('modules/cloud_service')
        local Identity=require('modules/book_identity')
        local Hash=require('modules/hash')
        local lfs=require('libs/libkoreader-lfs')
        local root=os.tmpname();os.remove(root);assert(lfs.mkdir(root));root=require('ffi/util').realpath(root)
        local function rm(p)
            local st=lfs.symlinkattributes(p);if not st then return end
            if st.mode=='directory'then for n in lfs.dir(p)do if n~='.' and n~='..'then rm(p..'/'..n)end end;lfs.rmdir(p)
            else os.remove(p)end
        end
        local ok,failure=pcall(function()
            local backend=assert(DAV:new{root_url=url,username='u',password='p',transport=function(req,cb)cb(Transport.perform(req))end})
            local namespace='def-test-'..assert(require('modules/random').hex(16))
            local made
            backend:mkdir(namespace,function(e)made=e or true end);assert.is_true(made)
            backend=assert(DAV:new{root_url=url..namespace..'/',username='u',password='p',transport=function(req,cb)cb(Transport.perform(req))end})
            local source=root..'/large.epub'
            local bytes='PK'..string.rep('test-EPUB-stream',100000)
            local file=assert(io.open(source,'wb'));file:write(bytes);file:close()
            local position='/body/p[9]/text().0'
            local context={book={file_path=source,file_name='large.epub',title='large',format='epub',
                size=#bytes,mtime=lfs.attributes(source,'modification')},progress={type='xpointer',value=position,percent=0.5}}
            local progress={_check_context=function()return true end,capture=function()return context end,
                apply=function(_,_,target,cb,opts)
                    for _,state in ipairs({'persisting_restore','applying','checking_position'})do opts.on_state(state)end
                    position=target.value;cb(nil,{})
                end}
            local identity=Identity:new{dir=root..'/settings'}
            local cloud=Cloud:new{backend=backend,identity=identity,progress=progress,
                state=require('modules/sync_state'):new{dir=root..'/settings'},
                config=require('modules/config_store'):new{dir=root..'/settings'},temp_dir=root..'/transfers'}
            local function run(method,...)
                local args,n={...},select('#',...);local e,value,count=nil,nil,0
                args[n+1]=function(err,v)e=err;value=v;count=count+1 end
                cloud[method](cloud,unpack(args,1,n+1))
                assert.is_equal(1,count);assert.is_nil(e)
                return value
            end
            local opts={schedule=function(cb)cb()end,confirm=function(_,cb)cb(true)end,home_dir=root..'/downloads'}
            assert(lfs.mkdir(opts.home_dir))
            local uploaded=run('upload_book',context,opts)
            assert.is_equal(require('modules/book_name').id(context.book.file_name),uploaded.record.bookId)
            local list=run('list',opts);assert.is_equal(1,#list.entries)
            local downloaded=run('download_book',list.entries[1],opts)
            local output=assert(io.open(downloaded.path,'rb'));assert.is_equal(bytes,output:read('*a'));output:close()
            local e
            backend:upload('books/External.EPUB',source,nil,function(err)e=err end,{precondition={unconditional=true}})
            assert.is_nil(e)
            local sent,status=Transport.perform{url=backend.root..'books/bad%25.epub',method='PUT',body='bad name',username='u',password='p'}
            assert.is_nil(sent);assert.is_truthy(status.status>=200 and status.status<300)
            local refreshed=run('list',{reconcile_books=true,confirm=opts.confirm,schedule=opts.schedule})
            assert.is_equal(1,refreshed.refresh_summary.added);assert.is_equal(1,refreshed.refresh_summary.skipped)
            local external
            for _,item in ipairs(refreshed.entries)do if item.record.bookId=='External'then external=item end end
            assert.is_truthy(external);assert.is_equal('books/External.EPUB',external.record.path)
            local imported=run('download_book',external,opts)
            local input=assert(io.open(imported.path,'rb'));assert.is_equal(bytes,input:read('*a'));input:close()
            run('delete_book',external,opts)
            local first=run('progress_operation','upload',context,opts)
            assert.is_equal(1,first.record.sync.revision)
            context.progress={type='xpointer',value='/body/p[1]/text().0',percent=0.1}
            run('progress_operation','download',context,opts)
            assert.is_equal('/body/p[9]/text().0',position)
            assert.is_equal(first.record.sync.writeId,run('progress_operation','query',context,opts).remote.record.sync.writeId)

        end)
        rm(root)
        assert.is_true(ok,tostring(failure))
    end)
end)
