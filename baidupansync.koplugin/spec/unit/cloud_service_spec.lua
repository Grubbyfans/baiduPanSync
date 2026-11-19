describe('WebDAV D/E/F orchestration',function()
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
    it('uploads, queries and applies progress with backend-isolated committed baselines',function()
        local first=run('progress_operation','upload',context,options());assert.is_nil(first.e)
        assert.is_equal(1,first.value.record.sync.revision)
        local id=first.value.record.book.id
        assert.is_truthy(state:get(backend.backend_id,id))
        assert.is_nil(state:get(Hash.sha256_text('another backend'),id))
        position='/body/p[1]/text().0';context=capture()
        local query=run('progress_operation','query',context,options());assert.is_nil(query.e)
        assert.is_equal('/body/p[4]/text().0',query.value.remote.record.progress.value)
        local downloaded=run('progress_operation','download',context,options());assert.is_nil(downloaded.e)
        assert.is_equal('/body/p[4]/text().0',position)
        assert.is_equal(1,progress.applies)
        assert.is_equal(id,context.book.content_sha256)
    end)
    it('publishes a bounded thumbnail and preserves it when the renderer is unavailable',function()
        local cover='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGNoAAAAggCBd81ytgAAAABJRU5ErkJggg=='
        local uploaded=run('upload_book',context,options{make_cover=function()return cover end})
        assert.is_nil(uploaded.e)
        local list=run('list',options());assert.is_nil(list.e)
        assert.is_equal(cover,list.value.entries[1].record.coverPng)
        local again=run('upload_book',context,options{
            make_cover=function()error('renderer unavailable')end,
            confirm=function(_,done)done{mode='overwrite',book_id=list.value.entries[1].record.bookId}end,
        })
        assert.is_nil(again.e)
        list=run('list',options());assert.is_equal(cover,list.value.entries[1].record.coverPng)
    end)
    it('reconfirms a changed same-revision record instead of reusing approval',function()
        local first=run('progress_operation','upload',context,options());assert.is_nil(first.e)
        position='/body/p[8]/text().0';context=capture()
        local confirmations=0
        local uploaded=run('progress_operation','upload',context,options{confirm=function(info,done)
            confirmations=confirmations+1
            if confirmations==1 then
                local record=info.remote.record;record.sync.writeId='other-writer';record.progress.value='/body/p[6]/text().0'
                backend.files['progress/'..record.book.id..'.json']=assert(Record.encode(record))
            end
            done(true)
        end})
        assert.is_nil(uploaded.e);assert.is_equal(2,confirmations)
        assert.is_equal(2,uploaded.value.record.sync.revision)
    end)
    it('does not interpret network failure as missing progress or commit a baseline',function()
        backend.hook=function(method,path)if method=='stat' and path:match('^progress/.+json$')then return Errors.new('NETWORK','offline')end end
        local r=run('progress_operation','upload',context,options())
        assert.is_equal('NETWORK',r.e.code)
        assert.is_equal(0,#backend.writes)
    end)
    it('keeps the baseline unchanged when navigation fails',function()
        local uploaded=run('progress_operation','upload',context,options());assert.is_nil(uploaded.e)
        local id=uploaded.value.record.book.id
        assert(state:delete(backend.backend_id,id))
        progress.apply_error=Errors.new('UNCERTAIN','navigation unverified',{outcome='uncertain'})
        position='/body/p[1]/text().0';context=capture()
        local r=run('progress_operation','download',context,options())
        assert.is_equal('UNCERTAIN',r.e.code);assert.is_nil(state:get(backend.backend_id,id))
    end)
    it('publishes the sidecar last and lists only complete book/metadata intersections',function()
        local entry=published()
        assert.is_equal('books/'..entry.record.bookId..'.epub',backend.writes[1])
        assert.is_equal('metadata/'..entry.record.bookId..'.json',backend.writes[2])
        assert.is_equal('size',entry.record.verificationLevel)
        backend.files['books/'..string.rep('a',64)..'.epub']='orphan'
        assert.is_equal(1,#run('list',options()).value.entries)
    end)
    it('prompts for identical content too and renames only its single publication',function()
        local entry=published();local prompts=0
        local r=run('upload_book',context,options{confirm=function(info,done)
            prompts=prompts+1;assert.is_equal(entry.record.bookId,info.candidates[1].record.bookId)
            done{mode='rename',name='renamed.epub'}
        end})
        assert.is_nil(r.e);assert.is_equal(1,prompts)
        local list=run('list',options()).value.entries
        assert.is_equal(1,#list);assert.is_equal('renamed.epub',Meta.filename(list[1].record))
    end)
    it('replaces a same-name different book by publishing new identity and withdrawing only old metadata',function()
        local old=published()
        local oldprogress='progress/'..old.record.bookId..'.json';backend.files[oldprogress]='retained'
        book=write(root..'/another.epub','another EPUB content');context=capture()
        local r=run('upload_book',context,options{confirm=function(info,done)
            assert.is_true(info.identity.book_id~=old.record.bookId)
            done{mode='overwrite',book_id=old.record.bookId}
        end})
        assert.is_nil(r.e)
        assert.is_nil(backend.files['metadata/'..old.record.bookId..'.json'])
        assert.is_truthy(backend.files[old.record.path]);assert.is_equal('retained',backend.files[oldprogress])
        assert.is_equal(1,#run('list',options()).value.entries)
    end)
    it('recovers an interrupted publication by checking the existing full bytes',function()
        local id=Hash.sha256_text(read(book));backend.dirs.books=true;backend.dirs.metadata=true
        backend.files['books/'..id..'.epub']=read(book)
        local r=run('upload_book',context,options{confirm=function(info,done)
            assert.is_truthy(info.recovery);done{mode='overwrite',book_id=id}
        end})
        assert.is_nil(r.e);assert.is_equal('sha256',r.value.record.verificationLevel)
        assert.is_equal('metadata/'..id..'.json',backend.writes[1])
    end)
    it('rejects contradictory orphan content without publishing it',function()
        local id=Hash.sha256_text(read(book));backend.dirs.books=true;backend.dirs.metadata=true
        backend.files['books/'..id..'.epub']='wrong EPUB bytes'
        local r=run('upload_book',context,options{confirm=function(_,done)done{mode='overwrite',book_id=id}end})
        assert.is_equal('CONFLICT',r.e.code);assert.is_nil(backend.files['metadata/'..id..'.json'])
    end)
    it('requires home_dir before downloading and makes no network request',function()
        local entry=published();backend.calls={}
        local r=run('download_book',entry,options{home_dir=' '})
        assert.is_equal('IO',r.e.code);assert.is_equal(0,#backend.calls)
        r=run('download_book',entry,options{home_dir=false})
        assert.is_equal('INVALID_INPUT',r.e.code)
    end)
    it('downloads to home_dir, validates bytes and never applies progress automatically',function()
        local entry=published()
        local r=run('download_book',entry,options());assert.is_nil(r.e)
        assert.is_equal(read(book),read(r.value.path))
        assert.is_truthy(r.value.path:match('/downloads/same%.epub$'))
        assert.is_equal(0,progress.applies)
    end)
    it('recursively prompts on identical local names and preserves an overwritten backup',function()
        local entry=published();assert(lfs.mkdir(root..'/downloads/nested'))
        local existing=write(root..'/downloads/nested/same.epub',read(book));local count=0
        local r=run('download_book',entry,options{confirm=function(info,done)
            count=count+1;assert.is_true(info.candidates[1].same)
            done{mode='overwrite',path=existing}
        end})
        assert.is_nil(r.e);assert.is_equal(1,count)
        assert.is_equal(existing,r.value.path);assert.is_equal(read(book),read(r.value.backup))
    end)
    it('shows different local identity and supports rename without touching the old file',function()
        local entry=published();local existing=write(root..'/downloads/same.epub','different')
        local r=run('download_book',entry,options{confirm=function(info,done)
            assert.is_false(info.candidates[1].same);done{mode='rename',name='new name.epub'}
        end})
        assert.is_nil(r.e);assert.is_equal('different',read(existing))
        assert.is_equal(read(book),read(r.value.path))
    end)
    it('rejects corrupted cloud EPUB bytes and leaves the existing local book untouched',function()
        local entry=published();backend.files[entry.record.path]=string.rep('x',entry.record.size)
        local existing=write(root..'/downloads/same.epub','old book')
        local r=run('download_book',entry,options{confirm=function(_,done)done{mode='overwrite',path=existing}end})
        assert.is_equal('CONFLICT',r.e.code);assert.is_equal('old book',read(existing))
    end)
    it('does not follow local symlinks and refuses covering an opened document',function()
        local entry=published();local external=root..'/external';assert(lfs.mkdir(external))
        write(external..'/same.epub','outside')
        assert(lfs.link(external,root..'/downloads/link',true))
        local r=run('download_book',entry,options());assert.is_nil(r.e)
        local target=r.value.path
        r=run('download_book',entry,options{current_path=function()return target end,
            confirm=function(_,done)done{mode='overwrite',path=target}end})
        assert.is_equal('CONFLICT',r.e.code)
        assert.is_equal('outside',read(external..'/same.epub'))
    end)
    it('retries a failed progress CAS only after another read and confirmation',function()
        local first=run('progress_operation','upload',context,options());assert.is_nil(first.e)
        position='/body/p[7]/text().0';context=capture()
        local prompts,raced=0,false
        backend.hook=function(method,path)
            if method=='put' and path:match('^progress/') and not raced then
                raced=true
                local v=assert(Record.decode(backend.files[path]));v.sync.writeId='racer';v.sync.revision=v.sync.revision+1
                v.progress.value='/body/p[2]/text().0';backend.files[path]=assert(Record.encode(v))
            end
        end
        local r=run('progress_operation','upload',context,options{confirm=function(_,done)prompts=prompts+1;done(true)end})
        assert.is_nil(r.e);assert.is_equal(2,prompts);assert.is_equal(3,r.value.record.sync.revision)
    end)
    it('reports uncertain after a successful progress write whose readback fails',function()
        local wrote=false
        backend.hook=function(method,path)
            if method=='put' and path:match('^progress/') then wrote=true end
            if wrote and method=='stat' and path:match('^progress/') then return Errors.new('NETWORK','readback offline')end
        end
        local r=run('progress_operation','upload',context,options())
        assert.is_equal('UNCERTAIN',r.e.code)
        assert.is_nil(state:get(backend.backend_id,Hash.sha256_text(read(book))))
    end)
    it('keeps an unconfirmed EPUB recoverable when sidecar publication fails',function()
        backend.hook=function(method,path)if method=='put' and path:match('^metadata/')then return Errors.new('NETWORK','offline')end end
        local r=run('upload_book',context,options());assert.is_equal('UNCERTAIN',r.e.code)
        local id=Hash.sha256_text(read(book));assert.is_truthy(backend.files['books/'..id..'.epub'])
        assert.is_nil(backend.files['metadata/'..id..'.json'])
        backend.hook=nil
        r=run('upload_book',context,options{confirm=function(_,done)done{mode='overwrite',book_id=id}end})
        assert.is_nil(r.e);assert.is_equal('sha256',r.value.record.verificationLevel)
    end)
    it('rejects an existing file changed after user approval without discarding its new contents',function()
        local entry=published();local existing=write(root..'/downloads/same.epub','original')
        local r=run('download_book',entry,options{confirm=function(info,done)
            write(existing,'changed by external application')
            done{mode='overwrite',path=info.candidates[1].path}
        end})
        assert.is_equal('CONFLICT',r.e.code);assert.is_equal('changed by external application',read(existing))
    end)
    it('never applies navigation or writes data after confirmation cancellation',function()
        local first=run('progress_operation','upload',context,options());assert.is_nil(first.e)
        local writes=#backend.writes
        local r=run('progress_operation','download',context,options{confirm=function(_,done)done(false)end})
        assert.is_equal('CANCELLED',r.e.code);assert.is_equal(0,progress.applies);assert.is_equal(writes,#backend.writes)
    end)
    it('backs up old metadata byte-for-byte without evaluating settings Lua',function()
        local original=package.loaded.docsettings
        local dirs={}
        for _,where in ipairs({'doc','dir','hash'})do
            dirs[where]=root..'/metadata-'..where;assert(lfs.mkdir(dirs[where]))
        end
        local payload='error("must never execute") -- old reading position'
        local old=write(dirs.doc..'/metadata.epub.lua',payload)
        package.loaded.docsettings={getSidecarDir=function(_,_,where)return dirs[where]end,findSidecarFile=function()return old end}
        local ok,backups=pcall(require('modules/local_library').backup_metadata,book)
        package.loaded.docsettings=original
        assert.is_true(ok,tostring(backups));assert.is_equal(1,#backups)
        assert.is_nil(lfs.attributes(old));assert.is_equal(payload,read(backups[1].backup))
    end)

    it('permits explicitly confirmed best-effort progress when atomic writes are unavailable',function()
        backend.conditional_verified=false
        backend.hook=function(method,path)
            if method=='put' and path:match('^%.baidupansync%-probe')then return Errors.new('UNSUPPORTED','no conditional support')end
        end
        local r=run('progress_operation','upload',context,options{confirm=function(info,done)
            assert.is_true(info.best_effort);done(true)
        end})
        assert.is_nil(r.e);assert.is_true(r.value.uploaded)
    end)
    it('does not withdraw published books without a verified conditional delete',function()
        local old=published()
        backend.conditional_delete_verified=false
        backend.hook=function(method,path)
            if method=='delete' then return Errors.new('UNSUPPORTED','no conditional deletion')end
        end
        book=write(root..'/new.epub','new content');context=capture()
        local r=run('upload_book',context,options{confirm=function(_,done)done{mode='overwrite',book_id=old.record.bookId}end})
        assert.is_equal('UNSUPPORTED',r.e.code)
        assert.is_truthy(backend.files['metadata/'..old.record.bookId..'.json'])
        assert.is_nil(backend.files['books/'..Hash.sha256_text('new content')..'.epub'])
    end)

    it('allows remote diagnostics but blocks baseline writes with a future local state version',function()
        local first=run('progress_operation','upload',context,options());assert.is_nil(first.e)
        write(state:get_path(),'{"schemaVersion":99,"data":{"baselines":{}}}')
        local query=run('progress_operation','query',context,options());assert.is_nil(query.e)
        assert.is_truthy(query.value.remote)
        local writes=#backend.writes
        local second=run('progress_operation','upload',context,options())
        assert.is_equal('UNSUPPORTED',second.e.code);assert.is_equal(writes,#backend.writes)
    end)

    it('keeps UTF-8 backup names within filesystem limits when overwriting a long book name',function()
        context.book.file_name=string.rep('书',160)..'.epub'
        local entry=published()
        local filename=Meta.filename(entry.record)
        local existing=write(root..'/downloads/'..filename,'old bytes')
        local r=run('download_book',entry,options{confirm=function(info,done)done{mode='overwrite',path=info.candidates[1].path}end})
        assert.is_nil(r.e);assert.is_equal('old bytes',read(r.value.backup))
        assert.is_true(#require('ffi/util').basename(r.value.backup)<=255)
    end)

    it('does not turn a weak resource ETag into strong overwrite permission',function()
        local initial=run('progress_operation','upload',context,options());assert.is_nil(initial.e)
        local original=backend.stat
        backend.stat=function(self,path,cb)
            original(self,path,function(e,v)
                if not e and v.type=='file' then v.etag='W/'..v.etag;v.weak_etag=true end
                cb(e,v)
            end)
        end
        position='/body/p[14]/text().0';context=capture()
        local approved=false
        local r=run('progress_operation','upload',context,options{confirm=function(info,done)
            assert.is_true(info.best_effort);approved=true;done(true)
        end})
        assert.is_nil(r.e);assert.is_true(approved);assert.is_equal(2,r.value.record.sync.revision)
    end)

    it('keeps partial deletions actionable and allows unrelated uploads',function()
        local entry=published()
        backend.files['progress/'..entry.record.bookId..'.json']='old progress'
        backend.hook=function(method,path)
            if method=='delete' and path:match('^progress/') then return Errors.new('NETWORK','disconnect') end
        end
        assert.is_equal('UNCERTAIN',run('delete_book',entry,options()).e.code)
        backend.hook=nil
        local listed=run('list',options()).value
        assert.is_equal(1,#listed.entries);assert.is_true(listed.entries[1].incomplete)
        assert.is_nil(listed.entries[1].book_stat)
        local cache=require('modules/library_cache'):new(root..'/cache')
        assert(cache:save(backend.backend_id,listed))
        assert.is_true(cache:load(backend.backend_id,backend.root).entries[1].incomplete)
        book=write(root..'/unrelated.epub','unrelated EPUB');context=capture()
        context.book.file_name='unrelated.epub'
        assert.is_nil(run('upload_book',context,options()).e)
        assert.is_nil(run('delete_book',listed.entries[1],options()).e)
        assert.is_nil(backend.files['metadata/'..entry.record.bookId..'.json'])
        assert.is_nil(backend.files['progress/'..entry.record.bookId..'.json'])
        assert.is_equal(1,#run('list',options()).value.entries)
    end)

    it('restores a missing EPUB through reupload and clears the incomplete cache flag',function()
        local entry=published();backend.files[entry.record.path]=nil
        local listed=run('list',options()).value
        assert.is_true(listed.entries[1].incomplete)
        assert.is_nil(run('upload_book',context,options{confirm=function(_,cb)
            cb{mode='overwrite',book_id=entry.record.bookId}
        end}).e)
        local fresh=run('list',options{cached_result=listed}).value
        assert.is_nil(fresh.entries[1].incomplete);assert.is_equal(0,#fresh.issues)
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

    it('cleans only a damaged publication and preserves EPUB and progress for repair',function()
        local entry=published();local id=entry.record.bookId;local path='metadata/'..id..'.json'
        backend.files[path]='{}';backend.files['progress/'..id..'.json']='keep progress'
        local listed=run('list',options()).value
        local items=require('modules/library_issues').collect(listed)
        assert.is_equal(1,#items);assert.is_truthy(items[1].cleanup)
        local cache=require('modules/library_cache'):new(root..'/cache')
        assert(cache:save(backend.backend_id,listed))
        local cached=cache:load(backend.backend_id,backend.root)
        local issue=require('modules/library_issues').collect(cached)[1].cleanup
        local cleaned=run('cleanup_issue',issue,options())
        assert.is_nil(cleaned.e);assert.is_nil(backend.files[path])
        assert.is_equal(read(book),backend.files[entry.record.path])
        assert.is_equal('keep progress',backend.files['progress/'..id..'.json'])
        local orphan=run('list',options()).value.unpublished[1]
        local repaired=run('repair_book',orphan,options{confirm=function(_,cb)cb{title='恢复后的书籍'}end})
        assert.is_nil(repaired.e);assert.is_truthy(backend.files[path])
    end)
    it('rejects valid or future-version metadata even when a cached hint requests cleanup',function()
        local entry=published();local id=entry.record.bookId;local path='metadata/'..id..'.json'
        local hint={kind='metadata',backend_id=backend.backend_id,book_id=id,path=path,stat=entry.stat}
        assert.is_equal('CONFLICT',run('cleanup_issue',hint,options()).e.code)
        backend.files[path]='{"schemaVersion":99}'
        local issue=run('list',options()).value.issues[1]
        assert.is_false(issue.cleanup_allowed)
        hint.stat=issue.stat
        assert.is_equal('UNSUPPORTED',run('cleanup_issue',hint,options()).e.code)
        assert.is_truthy(backend.files[entry.record.path]);assert.is_truthy(backend.files[path])
    end)
    it('requires confirmation and rejects a version that changes during cleanup',function()
        local entry=published();local path='metadata/'..entry.record.bookId..'.json';backend.files[path]='{'
        local issue=require('modules/library_issues').collect(run('list',options()).value)[1].cleanup
        assert.is_equal('CANCELLED',run('cleanup_issue',issue,options{confirm=function(_,cb)cb(false)end}).e.code)
        assert.is_equal('{',backend.files[path])
        local changed=run('cleanup_issue',issue,options{confirm=function(_,cb)backend.files[path]='new bytes';cb(true)end})
        assert.is_equal('CONFLICT',changed.e.code);assert.is_equal('new bytes',backend.files[path])
    end)
    it('deletes only an unpublished EPUB and refuses one published during confirmation',function()
        local entry=published();local id=entry.record.bookId;local meta='metadata/'..id..'.json'
        local raw=backend.files[meta];backend.files[meta]=nil;backend.files['progress/'..id..'.json']='keep'
        local hint=require('modules/library_issues').collect(run('list',options()).value)[1].cleanup
        local raced=run('cleanup_issue',hint,options{confirm=function(_,cb)backend.files[meta]=raw;cb(true)end})
        assert.is_equal('CONFLICT',raced.e.code);assert.is_truthy(backend.files[entry.record.path])
        backend.files[meta]=nil
        assert.is_nil(run('cleanup_issue',hint,options()).e)
        assert.is_nil(backend.files[entry.record.path]);assert.is_equal('keep',backend.files['progress/'..id..'.json'])
    end)
    it('rejects foreign and arbitrary cleanup paths before any deletion',function()
        local id=string.rep('a',64)
        local hint={kind='metadata',backend_id='foreign',book_id=id,path='metadata/'..id..'.json'}
        assert.is_equal('FORBIDDEN',run('cleanup_issue',hint,options()).e.code)
        hint.backend_id=backend.backend_id;hint.path='../credentials.json'
        assert.is_equal('FORBIDDEN',run('cleanup_issue',hint,options()).e.code)
        assert.is_equal(0,#backend.writes)
    end)
    it('times out a stalled qualification without leaving temporary write permissions',function()
        local timers,err={}
        backend.conditional_verified=false;backend.conditional_delete_verified=false
        backend.uploadSmallJson=function()end
        service:upload_book(context,options{
            watchdog_schedule=function(_,cb)timers[cb]=true end,
            watchdog_unschedule=function(cb)timers[cb]=nil end,
        },function(e)err=e end)
        assert.is_true(backend.conditional_verified)
        local expire=next(timers);assert.is_truthy(expire);expire()
        assert.is_equal('NETWORK',err.code)
        assert.is_false(service.active);assert.is_false(backend.conditional_verified)
        assert.is_false(backend.conditional_delete_verified)
        assert.is_true(service.task:is_terminal())
    end)

end)
