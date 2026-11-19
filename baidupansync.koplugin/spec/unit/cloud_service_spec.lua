describe('single-writer name-based catalog',function()
    local Cloud,Backend,Identity,Config,State,Hash,Meta,Record,Errors,lfs
    local root,book,context,backend,identity,config,state,progress,service,position
    local function write(path,raw)local f=assert(io.open(path,'wb'));f:write(raw);f:close();return path end
    local function read(path)local f=assert(io.open(path,'rb'));local s=f:read('*a');f:close();return s end
    local function rm(path)
        local st=lfs.symlinkattributes(path);if not st then return end
        if st.mode=='directory'then
            for n in lfs.dir(path)do if n~='.' and n~='..'then rm(path..'/'..n)end end
            lfs.rmdir(path)
        else os.remove(path)end
    end
    local function capture()
        return {book={file_path=book,file_name='same.epub',title='Test EPUB',format='epub',
            size=lfs.attributes(book,'size'),mtime=lfs.attributes(book,'modification')},
            progress={type='xpointer',value=position,percent=0.4}}
    end
    local function options(extra)
        local o={schedule=function(cb)cb()end,home_dir=root..'/downloads',confirm=function(_,done)done(true)end}
        for k,v in pairs(extra or {})do o[k]=v end
        return o
    end
    local function run(method,...)
        local args,n={...},select('#',...);local result={count=0}
        args[n+1]=function(e,v)result.e=e;result.value=v;result.count=result.count+1 end
        service[method](service,unpack(args,1,n+1))
        assert.is_equal(1,result.count)
        return result
    end
    local function published()
        local r=run('upload_book',context,options())
        assert.is_nil(r.e)
        local list=run('list',options());assert.is_nil(list.e)
        assert.is_equal(1,#list.value.entries)
        return list.value.entries[1]
    end
    setup(function()
        require('commonrequire');Cloud=require('modules/cloud_service');Backend=require('spec/fixtures/fake_backend')
        Identity=require('modules/book_identity');Config=require('modules/config_store');State=require('modules/sync_state')
        Hash=require('modules/hash');Meta=require('modules/book_metadata');Record=require('modules/progress_record')
        Errors=require('modules/errors');lfs=require('libs/libkoreader-lfs')
    end)
    before_each(function()
        root=os.tmpname();os.remove(root);assert(lfs.mkdir(root));root=require('ffi/util').realpath(root);assert(lfs.mkdir(root..'/downloads'))
        book=write(root..'/source.epub','PK-test-EPUB-bytes')
        position='/body/p[4]/text().0'
        context=capture();backend=Backend:new()
        identity=Identity:new{dir=root..'/state'};config=Config:new{dir=root..'/state'};state=State:new{dir=root..'/state'}
        progress={applies=0,_check_context=function()return true end,capture=function()return capture()end,
            apply=function(self,ctx,p,cb,opts)
                self.applies=self.applies+1
                if self.apply_error then return cb(self.apply_error)end
                for _,s in ipairs({'persisting_restore','applying','checking_position'})do opts.on_state(s)end
                position=p.value;cb(nil,{})
            end}
        service=Cloud:new{backend=backend,identity=identity,progress=progress,state=state,config=config,temp_dir=root..'/temporary',now=function()return 1794900000 end}
    end)
    after_each(function()rm(root)end)
    it('uploads without invoking content identity or enumerating directories once initialized',function()
        identity.identify=function()error('must not hash content')end
        backend.files['library.json']='{"schemaVersion":2,"books":[]}'
        local r=run('upload_book',context,options());assert.is_nil(r.e)
        assert.is_equal('same',r.value.record.bookId)
        assert.is_equal(read(book),backend.files['books/same.epub'])
        assert.is_nil(r.value.record.contentSha256)
        assert.is_equal(3,#backend.calls)
        assert.is_equal('download',backend.calls[1].method)
        assert.is_equal('library.json',backend.calls[1].path)
        assert.is_equal('upload',backend.calls[2].method)
        assert.is_equal('library.json',backend.calls[3].path)
    end)
    it('keeps request count constant for 20 and 100 existing books',function()
        local Catalog=require('modules/library_catalog')
        for _,n in ipairs({20,100})do
            local catalog=Catalog.empty()
            for i=1,n do
                local id='book'..i
                catalog.books[i]={schemaVersion=2,status='ready',bookId=id,title=id,fileName=id..'.epub',
                    path='books/'..id..'.epub',size=10,uploadedAt=Record.iso_timestamp(os.time())}
            end
            backend.files['library.json']=assert(Catalog.encode(catalog));backend.calls={}
            local r=run('upload_book',context,options());assert.is_nil(r.e)
            assert.is_equal(3,#backend.calls);assert.is_equal(n+1,#r.value.library.entries)
        end
    end)
    it('overwrites different bytes by filename and keeps cloud progress byte-for-byte',function()
        assert.is_nil(run('upload_book',context,options()).e)
        local first=run('progress_operation','upload',context,options());assert.is_nil(first.e)
        local raw=backend.files['progress/same.json']
        write(book,'completely different EPUB bytes and size');context=capture()
        assert.is_nil(run('upload_book',context,options{confirm=function()error('no overwrite prompt')end}).e)
        assert.is_equal(raw,backend.files['progress/same.json'])
        local query=run('progress_operation','query',context,options());assert.is_nil(query.e)
        assert.is_equal(first.value.record.progress.value,query.value.remote.record.progress.value)
        assert.is_nil(run('progress_operation','download',context,options()).e)
        assert.is_equal('same',context.book.name_identity)
    end)
    it('uses only the catalog for browsing and never discovers orphan files',function()
        backend.files['books/old.epub']='orphan';backend.files['metadata/old.json']='{}'
        local r=run('list',options());assert.is_nil(r.e);assert.is_equal(0,#r.value.entries)
        assert.is_equal(1,#backend.calls);assert.is_equal('library.json',backend.calls[1].path)
    end)
    it('does not overwrite malformed or future catalogs with an empty library',function()
        for _,raw in ipairs({'{','{"schemaVersion":99,"books":[]}','{"schemaVersion":2,"books":{"bad":{}}}'})do
            backend.files['library.json']=raw
            local r=run('upload_book',context,options());assert.is_truthy(r.e)
            assert.is_equal(raw,backend.files['library.json']);assert.is_equal(0,#backend.writes)
        end
    end)
    it('rejects ambiguous or escaping book names before writing',function()
        for _,name in ipairs({'../escape.epub','bad%.epub','bad?.epub','..epub',' leading.epub'})do
            context.book.file_name=name
            local r=run('upload_book',context,options());assert.is_truthy(r.e)
        end
        assert.is_equal(0,#backend.writes)
    end)
    it('stores thumbnails outside the catalog and keeps the previous cover if unavailable',function()
        local cover='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGNoAAAAggCBd81ytgAAAABJRU5ErkJggg=='
        local r=run('upload_book',context,options{make_cover=function()return cover end});assert.is_nil(r.e)
        assert.is_nil(r.value.record.coverPng);assert.is_equal('covers/same.json',r.value.record.coverPath)
        assert.is_truthy(backend.files['covers/same.json'])
        assert.is_nil(backend.files['library.json']:find(cover,1,true))
        local version=r.value.record.coverVersion
        r=run('upload_book',context,options());assert.is_nil(r.e)
        assert.is_equal(version,r.value.record.coverVersion)
    end)
    it('reports partial publication without pretending the catalog is committed',function()
        backend.hook=function(method,path)if method=='put' and path=='library.json' then return Errors.new('NETWORK','offline')end end
        local r=run('upload_book',context,options());assert.is_equal('UNCERTAIN',r.e.code)
        assert.is_equal(read(book),backend.files['books/same.epub']);assert.is_nil(backend.files['library.json'])
        backend.hook=nil;assert.is_nil(run('upload_book',context,options()).e)
    end)
    it('persists confirmed EPUB recovery and republishes only the catalog after restart',function()
        backend.hook=function(method,path)if method=='put' and path=='library.json'then return Errors.new('NETWORK','offline')end end
        local first=run('upload_book',context,options());assert.is_equal('catalog',first.e.detail.stage)
        local pending=assert(service.recovery:list(backend.backend_id));assert.is_equal(1,#pending)
        local epub=backend.files['books/same.epub'];backend.hook=nil;backend.calls={}
        local restarted=Cloud:new{backend=backend,identity=identity,progress=progress,state=state,config=config,temp_dir=root..'/temporary'}
        local e,r;restarted:finish_publication(pending[1],options(),function(err,value)e=err;r=value end)
        assert.is_nil(e);assert.is_true(r.published);assert.is_equal(epub,backend.files['books/same.epub'])
        assert.is_equal(2,#backend.calls);assert.is_equal('download',backend.calls[1].method);assert.is_equal('put',backend.calls[2].method)
        assert.is_equal(0,#assert(service.recovery:list(backend.backend_id)))
        restarted:finish_publication(pending[1],options(),function(err)e=err end);assert.is_equal('NOT_FOUND',e.code)
    end)
    it('keeps recovery on a second catalog failure and isolates backends',function()
        backend.hook=function(method,path)if method=='put' and path=='library.json'then return Errors.new('NETWORK','offline')end end
        assert.is_equal('UNCERTAIN',run('upload_book',context,options()).e.code)
        local receipt=assert(service.recovery:list(backend.backend_id))[1]
        assert.is_truthy(run('finish_publication',receipt,options()).e)
        assert.is_equal(1,#assert(service.recovery:list(backend.backend_id)))
        receipt.backend_id=string.rep('b',64)
        assert.is_equal('CONFLICT',run('finish_publication',receipt,options()).e.code)
        assert.is_equal(0,#assert(service.recovery:list(receipt.backend_id)))
    end)
    it('does not offer catalog-only repair when EPUB upload itself was not confirmed',function()
        backend.hook=function(method)if method=='upload'then return Errors.new('NETWORK','offline')end end
        local r=run('upload_book',context,options())
        assert.is_equal('epub',r.e.detail.stage);assert.is_equal(0,#assert(service.recovery:list(backend.backend_id)))
    end)
    it('downloads by catalog path, checks size, and preserves local settings on same-name replacement',function()
        local entry=published()
        local r=run('download_book',entry,options());assert.is_nil(r.e)
        assert.is_equal(read(book),read(r.value.path))
        write(r.value.path,'old local bytes')
        local settings=write(root..'/downloads/metadata.epub.lua','keep reading position')
        r=run('download_book',entry,options{backup_metadata=function()error('must retain settings')end,
            confirm=function(info,cb)cb{mode='overwrite',path=info.candidates[1].path}end})
        assert.is_nil(r.e);assert.is_equal('old local bytes',read(r.value.backup))
        assert.is_equal('keep reading position',read(settings))
    end)
    it('downloads only to the registered path and updates the local index without rescanning',function()
        local Store=require('modules/local_books');local local_index=Store:new{dir=root..'/local-state'}
        local scanned
        local_index:scan(root..'/downloads',{schedule=function(cb)cb()end},function(e,v)assert.is_nil(e);scanned=v end)
        assert.is_truthy(scanned)
        local entry=published()
        local opts=options{local_index=local_index}
        local r=run('download_book',entry,opts);assert.is_nil(r.e)
        assert.is_equal(r.value.path,local_index:load(root..'/downloads').books.same.path)
        local original=require('modules/local_library').scan
        require('modules/local_library').scan=function()error('must not scan on download')end
        opts.confirm=function(info,cb)assert.is_true(info.unique_local);cb{mode='overwrite',path=info.candidates[1].path}end
        r=run('download_book',entry,opts)
        require('modules/local_library').scan=original
        assert.is_nil(r.e)
        opts.confirm=function(_,cb)cb{mode='rename',name='duplicate.epub'}end
        assert.is_equal('INVALID_INPUT',run('download_book',entry,opts).e.code)
    end)
    it('rejects truncated downloads and covering the currently open book',function()
        local entry=published();backend.files[entry.record.path]='short'
        assert.is_equal('INVALID_INPUT',run('download_book',entry,options()).e.code)
        backend.files[entry.record.path]=read(book)
        local r=run('download_book',entry,options());assert.is_nil(r.e)
        assert.is_equal('CONFLICT',run('download_book',entry,options{current_path=function()return r.value.path end,
            confirm=function(info,cb)cb{mode='overwrite',path=info.candidates[1].path}end}).e.code)
    end)
    it('deletes only the selected name and updates the catalog',function()
        local entry=published();backend.files['progress/same.json']='position'
        local r=run('delete_book',entry,options());assert.is_nil(r.e)
        assert.is_nil(backend.files[entry.record.path]);assert.is_nil(backend.files['progress/same.json'])
        assert.is_equal(0,#run('list',options()).value.entries)
    end)
    it('honors cancellation before writes or navigation',function()
        assert.is_nil(run('progress_operation','upload',context,options()).e)
        local n=#backend.writes
        local r=run('progress_operation','download',context,options{confirm=function(_,cb)cb(false)end})
        assert.is_equal('CANCELLED',r.e.code);assert.is_equal(n,#backend.writes);assert.is_equal(0,progress.applies)
    end)
    it('releases a stalled task once, cleans resources and prevents delayed writes',function()
        local A=require('modules/async')
        local timers,pending,count,err,cancelled={}
        count=0
        local o=options{watchdog_timeout=10,
            watchdog_schedule=function(_,cb)timers[cb]=true end,
            watchdog_unschedule=function(cb)timers[cb]=nil end}
        service:run('upload_book',o,function()
            service:step('reading_remote');service:step('rechecking');service:step('writing')
            local path=service:temporary(root..'/temporary')
            service.stalled_path=path
            A.call(function(cb)
                pending=cb;A.on_cancel(function()cancelled=true end)
            end)
            backend.files['should-not-exist']='late write'
        end,function(e)count=count+1;err=e;assert.is_true(cancelled)end)
        assert.is_true(service.active)
        local expire=next(timers);assert.is_truthy(expire);expire()
        assert.is_equal('UNCERTAIN',err.code);assert.is_false(service.active)
        assert.is_nil(lfs.attributes(service.stalled_path))
        local next_task=run('list',options());assert.is_nil(next_task.e)
        pending(nil,{});assert.is_equal(1,count);assert.is_nil(backend.files['should-not-exist'])
    end)

end)
