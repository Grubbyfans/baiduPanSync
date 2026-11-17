package.path='baidupansync.koplugin/?.lua;'..package.path
local function attr(path,key)local a=fixture_attributes(path);return key and a and a[key] or a end
package.loaded['libs/libkoreader-lfs']={attributes=attr,symlinkattributes=attr,mkdir=fixture_mkdir,rmdir=fixture_rmdir,
    dir=function(path)local names=fixture_listdir(path);local i=0;return function()i=i+1;return names[i]end end}
package.loaded['ffi/util']={realpath=fixture_realpath,basename=function(p)return p:match('([^/]+)$')end,
    fsyncOpenedFile=function()end,df=function()return 1e10,1e10,1e10 end}
package.loaded.ffi={cdef=function()end,cast=function(_,v)return v end,
    C={open=fixture_exclusive_open,close=fixture_close,O_CREAT=64,O_WRONLY=1}}
package.loaded['ffi/posix_h']=true
package.loaded.jit={os='Linux'};jit=package.loaded.jit
package.loaded.bit={bor=function(...)local n=0;for _,v in ipairs({...})do n=n+v end;return n end}
local nonce=0
package.loaded['modules/random']={hex=function(n)nonce=nonce+1;return string.format('%0'..(n*2)..'x',nonce)end}
package.loaded['socket.url']={parse=function(url)
    local scheme,host=url:match('^(https?)://([^/]+)');return {scheme=scheme,host=host}
end,absolute=function(_,url)return url end}
local Cloud=require('modules/cloud_service')
local Identity=require('modules/book_identity')
local Config=require('modules/config_store')
local State=require('modules/sync_state')
local Record=require('modules/progress_record')
local Fixture=require('spec/fixtures/baidu_cloud')
local json=require('json')
local Hash=require('modules/hash')
local root=fixture_temp_dir
fixture_mkdir(root..'/downloads')
local book=root..'/source.epub'
local function write(path,raw)local f=assert(io.open(path,'wb'));f:write(raw);f:close()end
local function read(path)local f=assert(io.open(path,'rb'));local raw=f:read('*a');f:close();return raw end
local raw='PK-test-full-book-with-中文-title'
write(book,raw)
local position='/body/p[3]/text().0'
local context={book={file_path=book,file_name='same.epub',title='中文书籍',format='epub',size=#raw,
    mtime=fixture_attributes(book).modification},progress={type='xpointer',value=position,percent=0.3}}
local applied=0
local progress={_check_context=function()return true end,apply=function(_,ctx,p,cb,opts)
    for _,s in ipairs({'persisting_restore','applying','checking_position'})do opts.on_state(s)end
    applied=applied+1;position=p.value;cb(nil,{})
end}
local remote=Fixture.new('/apps/fixture','9007199254740993123')
local identity=Identity:new{dir=root..'/state'}
local state=State:new{dir=root..'/state'}
local config=Config:new{dir=root..'/state'}
local function service(backend)
    local c=Cloud:new{backend=backend or remote.api(),identity=identity,progress=progress,state=state,
        config=config,temp_dir=root..'/transfers'}
    c.backend.operation_opts={schedule=function(cb)cb()end}
    return c
end
local options={schedule=function(cb)cb()end,home_dir=root..'/downloads',confirm=function(info,done)
    if info.kind=='upload_book' then done{mode='overwrite',book_id=info.identity.book_id}
    elseif info.kind=='download_book' then done{mode='overwrite',path=info.candidates[1].path}
    else assert(info.kind~='progress_upload' or info.best_effort);done(true)end
end}
local function run(c,method,...)
    local args={...};local result,count=nil,0
    args[#args+1]=function(e,v)result={e=e,value=v};count=count+1 end
    c[method](c,unpack(args));assert(count==1 and result)
    return result
end
local c=service()
local uploaded=run(c,'upload_book',context,options)
assert(not uploaded.e,uploaded.e and uploaded.e.message)
assert(uploaded.value.record.verificationLevel=='sha256')
local id=uploaded.value.record.bookId
assert(remote.files['/apps/fixture/books/'..id..'.epub'].raw==raw)
local listed=run(c,'list',options);assert(not listed.e and #listed.value.entries==1)
assert(listed.value.entries[1].record.title=='中文书籍')
local downloaded=run(c,'download_book',listed.value.entries[1],options)
assert(not downloaded.e,downloaded.e and downloaded.e.message)
assert(read(downloaded.value.path)==raw)
-- A second download explicitly confirms the existing same-name path and backs it up.
downloaded=run(c,'download_book',listed.value.entries[1],options)
assert(not downloaded.e and read(downloaded.value.backup)==raw)
local sent=run(c,'progress_operation','upload',context,options)
assert(not sent.e,sent.e and sent.e.message)
context.progress={type='xpointer',value='/body/p[7]/text().0',percent=0.7}
sent=run(c,'progress_operation','upload',context,options)
assert(not sent.e and sent.value.record.sync.revision==2)
local received=run(c,'progress_operation','download',context,options)
assert(not received.e and applied==1 and position=='/body/p[7]/text().0')
-- Re-publishing identical content updates the sidecar without replacing the EPUB.
local again=run(c,'upload_book',context,options)
assert(not again.e,again.e and again.e.message)
-- Different identities with the same filename require rename; no old sidecar is withdrawn.
write(book,'PK-other-content')
context.book.size=#'PK-other-content';context.book.mtime=fixture_attributes(book).modification
local refused=run(c,'upload_book',context,{schedule=options.schedule,confirm=function(info,done)
    assert(info.no_replace_other);done{mode='overwrite',book_id=id}
end})
assert(refused.e.code=='UNSUPPORTED')
local renamed=run(c,'upload_book',context,{schedule=options.schedule,confirm=function(_,done)done{mode='rename',name='另一册.epub'}end})
assert(not renamed.e,renamed.e and renamed.e.message)
assert(remote.files['/apps/fixture/metadata/'..id..'.json'])
-- Corrupt uploaded bytes are detected by full readback before sidecar publication.
write(book,'PK-corrupted-in-transit')
context.book.size=#'PK-corrupted-in-transit';context.book.mtime=fixture_attributes(book).modification
local bad_id=Hash.sha256_text('PK-corrupted-in-transit')
remote.after_create=function(path,value)
    if path:match('%.epub$')then remote.put(path,'X'..value:sub(2))end
end
local corrupted=run(c,'upload_book',context,{schedule=options.schedule,confirm=function(_,done)done{mode='rename',name='corrupt.epub'}end})
assert(corrupted.e and not remote.files['/apps/fixture/metadata/'..bad_id..'.json'])
remote.after_create=nil
write(book,raw);context.book.size=#raw;context.book.mtime=fixture_attributes(book).modification
local confirmations=0
context.progress={type='xpointer',value='/body/p[9]/text().0',percent=0.9}
remote.after_precreate=function(path)
    if path:match('^/apps/fixture/progress/') then
        local record=assert(Record.decode(remote.files[path].raw))
        record.sync.writeId='racer-before-commit';record.sync.revision=record.sync.revision+1
        remote.put(path,assert(Record.encode(record)))
    end
end
local raced=run(c,'progress_operation','upload',context,{schedule=options.schedule,confirm=function(info,done)
    confirmations=confirmations+1;done(confirmations==1)
end})
assert(raced.e.code=='CANCELLED' and confirmations==2)
assert(Record.decode(remote.files['/apps/fixture/progress/'..id..'.json'].raw).sync.writeId=='racer-before-commit')
remote.after_precreate=nil
local other=service(Fixture.new('/apps/other','2').api())
local wrong=run(other,'download_book',listed.value.entries[1],options)
assert(wrong.e.code=='CONFLICT')
assert(state:get(other.backend.backend_id,id)==nil,'backend baselines must remain independent')
-- Unverified JSON writes that are overtaken after commit must not advance the baseline.
local baseline=state:get(c.backend.backend_id,id)
write(book,raw);context.book.size=#raw;context.book.mtime=fixture_attributes(book).modification
context.progress={type='xpointer',value='/body/p[9]/text().0',percent=0.9}
remote.after_create=function(path,value)
    if path:match('^/apps/fixture/progress/') then
        local record=assert(Record.decode(value));record.sync.writeId='other-writer'
        remote.put(path,assert(Record.encode(record)))
    end
end
local uncertain=run(c,'progress_operation','upload',context,options)
assert(uncertain.e and uncertain.e.code=='UNCERTAIN')
assert(state:get(c.backend.backend_id,id).base_remote_fingerprint==baseline.base_remote_fingerprint)
remote.after_create=nil
-- Reusing the same orchestration for WebDAV must preserve its conditional flow.
local dav=require('spec/fixtures/fake_backend'):new()
local web=service(dav)
local web_book=run(web,'upload_book',context,options);assert(not web_book.e,web_book.e and web_book.e.message)
local web_list=run(web,'list',options);assert(not web_list.e and #web_list.value.entries==1)
local web_progress=run(web,'progress_operation','upload',context,{schedule=options.schedule,confirm=function(info,done)
    assert(not info.best_effort);done(true)
end})
assert(not web_progress.e,web_progress.e and web_progress.e.message)
assert(dav.backend_id~=c.backend.backend_id and state:get(dav.backend_id,id))
-- Pagination is consumed completely and repeated cursors are rejected.
local original_list=c.backend.list
local pages=0
c.backend.list=function(_,path,cursor,done)
    pages=pages+1
    done(nil,{entries={{path='part-'..tostring(cursor or 0)}},continuation=not cursor and 1000 or nil})
end
local collected
require('modules/async').run(function()return c:all_entries('metadata/')end,function(e,v)assert(not e);collected=v end)
assert(pages==2 and #collected==2)
c.backend.list=original_list
-- Delete requires explicit confirmation, stable snapshots and backend identity.
local function deletion_suite(s,entry,files,key,put)
    local paths={entry.record.path,'progress/'..entry.record.bookId..'.json','metadata/'..entry.record.bookId..'.json'}
    local function exists(path)return files[key(path)]~=nil end
    local cancel=run(s,'delete_book',entry,{confirm=function(info,done)
        assert(info.kind=='delete_book' and #info.paths==3);done(false)
    end})
    assert(cancel.e.code=='CANCELLED')
    for _,p in ipairs(paths)do assert(exists(p))end
    local before=files[key(paths[2])]
    local race=run(s,'delete_book',entry,{confirm=function(_,done)put(paths[2],'changed-progress');done(true)end})
    assert(race.e.code=='CONFLICT' and exists(paths[1]) and exists(paths[3]))
    if type(before)=='table' then put(paths[2],before.raw)else put(paths[2],before)end
    local wrong_entry={record=entry.record,backend_id='another-backend'}
    assert(run(s,'delete_book',wrong_entry,{confirm=function()error('must not confirm')end}).e.code=='CONFLICT')
    local complete=run(s,'delete_book',entry,{confirm=function(_,done)done(true)end})
    assert(not complete.e,complete.e and complete.e.message)
    for _,p in ipairs(paths)do assert(not exists(p))end
    assert(read(book)==raw,'deleting cloud files must preserve the local book')
end
deletion_suite(web,web_list.value.entries[1],dav.files,function(p)return p end,
    function(p,v)dav.files[p]=v end)
local fresh=run(c,'list',options)
local selected
for _,entry in ipairs(fresh.value.entries)do if entry.record.bookId==id then selected=entry end end
assert(selected)
deletion_suite(c,selected,remote.files,function(p)return '/apps/fixture/'..p end,
    function(p,v)remote.put('/apps/fixture/'..p,v)end)
-- A partial multi-file deletion must be reported as uncertain, never success.
assert(not run(web,'upload_book',context,options).e)
assert(not run(web,'progress_operation','upload',context,{schedule=options.schedule,confirm=function(_,done)done(true)end}).e)
local partial_entry=run(web,'list',options).value.entries[1]
dav.hook=function(method,path)
    if method=='delete' and path:match('^progress/')then return require('modules/errors').new('NETWORK','fixture failure')end
end
local partial=run(web,'delete_book',partial_entry,{confirm=function(_,done)done(true)end})
assert(partial.e.code=='UNCERTAIN' and partial.e.message:find('books/',1,true))
assert(dav.files['metadata/'..id..'.json'] and dav.files['progress/'..id..'.json'])
dav.hook=nil
local without_progress=service(require('spec/fixtures/fake_backend'):new())
assert(not run(without_progress,'upload_book',context,options).e)
local no_progress_entry=run(without_progress,'list',options).value.entries[1]
assert(not run(without_progress,'delete_book',no_progress_entry,{confirm=function(_,done)done(true)end}).e)
assert(#run(without_progress,'list',options).value.entries==0)
-- Production WebDAV adapter sends If-Match for book-owned files, never broad deletes.
local requests=0
local adapter=assert(require('modules/webdav'):new{root_url='https://example.com/sync/',username='u',password='p',
    conditional_verified=true,conditional_delete_verified=true,transport=function(req,done)
        requests=requests+1;assert(req.method=='DELETE' and req.headers['If-Match']=='"confirmed"')
        done(nil,{status=204})
    end})
for _,path in ipairs({'books/'..id..'.epub','progress/'..id..'.json','metadata/'..id..'.json'})do
    local err;adapter:delete(path,{etag='"confirmed"'},function(e)err=e end);assert(not err)
end
assert(requests==3)
local err;adapter:delete('books/'..id..'.epub',nil,function(e)err=e end)
assert(err.code=='FORBIDDEN' and requests==3)
adapter:delete('books/'..id..'.epub',{etag='W/"weak"'},function(e)err=e end)
assert(err.code=='INVALID_INPUT' and requests==3)
adapter.conditional_delete_verified=false
adapter:delete('books/'..id..'.epub',{etag='"confirmed"'},function(e)err=e end)
assert(err.code=='UNSUPPORTED' and requests==3)
-- Uploaded-but-unpublished books recover without re-uploading content after
-- a child download returns no result (the reported device failure sequence).
local recovery_remote=Fixture.new('/apps/recovery','3')
local recovery_api=recovery_remote.api()
local recovery=service(recovery_api)
local original_transport=recovery_api.transport
recovery_api.transport=function(req,done)
    if req.url:find('/download?',1,true) and req.download_path then return done(nil,nil)end
    return original_transport(req,done)
end
local failed_publish=run(recovery,'upload_book',context,options)
assert(failed_publish.e.code=='UNCERTAIN')
assert(failed_publish.e.message:find('从云端回读 EPUB',1,true) and failed_publish.e.message:find('未收到有效',1,true))
assert(recovery_remote.files['/apps/recovery/books/'..id..'.epub'])
assert(not recovery_remote.files['/apps/recovery/metadata/'..id..'.json'])
local upload_count=recovery_remote.uploads
recovery_api.transport=original_transport
local recovered=run(recovery,'upload_book',context,{schedule=options.schedule,confirm=function(info,done)
    assert(info.recovery);done{mode='overwrite',book_id=id}
end})
assert(not recovered.e,recovered.e and recovered.e.message)
assert(recovery_remote.uploads==upload_count+1,'recovery must only upload metadata, not the EPUB again')
assert(#run(recovery,'list',options).value.entries==1)
-- Recovery must also complete with real UI-style delayed confirmations,
-- deferred network callbacks, scheduled hashes and GC between every event.
recovery_remote.files['/apps/recovery/metadata/'..id..'.json']=nil
local queue={}
local function later(cb)queue[#queue+1]=cb end
recovery_api.transport=function(req,cb)later(function()original_transport(req,cb)end)end
local deferred,count=nil,0
local phases={}
recovery:upload_book(context,{schedule=later,on_phase=function(phase)phases[#phases+1]=phase end,confirm=function(info,cb)
    assert(info.recovery);later(function()cb{mode='overwrite',book_id=id}end)
end},function(e,v)count=count+1;deferred={e=e,value=v}end)
local iterations=0
while #queue>0 do
    iterations=iterations+1;assert(iterations<1000)
    collectgarbage('collect');table.remove(queue,1)()
end
assert(count==1 and deferred and not deferred.e,deferred and deferred.e and deferred.e.message or 'recovery silently stopped')
assert(recovery_remote.files['/apps/recovery/metadata/'..id..'.json'])
assert(table.concat(phases,'/'):find('从云端回读 EPUB',1,true) and phases[#phases]=='书库发布完成')
print('WebDAV/Baidu confirmed deletion, cancellation, races, partial failures and conditional DELETE regressions passed')
print('Baidu full book publish/list/download/backup/progress/rename, corruption and backend isolation regressions passed')
