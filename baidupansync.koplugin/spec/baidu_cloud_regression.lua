package.path='baidupansync.koplugin/?.lua;'..package.path
package.loaded['ui/uimanager']={scheduleIn=function()end,unschedule=function()end}
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
    else done(true)end
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
assert(uploaded.value.record.bookId=='same' and not uploaded.value.record.contentSha256)
assert(remote.files['/apps/fixture/books/same.epub'].raw==raw)
assert(remote.files['/apps/fixture/library.json'])
local listed=run(c,'list',options);assert(not listed.e and #listed.value.entries==1)
assert(listed.value.entries[1].record.title=='same')
local downloaded=run(c,'download_book',listed.value.entries[1],options)
assert(not downloaded.e,downloaded.e and downloaded.e.message)
assert(read(downloaded.value.path)==raw)
downloaded=run(c,'download_book',listed.value.entries[1],options)
assert(not downloaded.e and read(downloaded.value.backup)==raw)
local sent=run(c,'progress_operation','upload',context,options)
assert(not sent.e,sent.e and sent.e.message)
local old_progress=remote.files['/apps/fixture/progress/same.json'].raw
write(book,'PK-other-content');context.book.size=#'PK-other-content';context.book.mtime=fixture_attributes(book).modification
assert(not run(c,'upload_book',context,options).e)
assert(remote.files['/apps/fixture/progress/same.json'].raw==old_progress)
assert(not run(c,'progress_operation','download',context,options).e and applied==1)
-- Normal upload has constant HTTP request count regardless of library size.
local Catalog=require('modules/library_catalog')
local sample=string.rep('x',10*1024*1024)
write(book,sample);context.book.size=#sample;context.book.mtime=fixture_attributes(book).modification
remote.dirs['/apps/fixture/books']=true
for _,n in ipairs({20,100})do
    local catalog=Catalog.empty()
    for i=1,n do
        local id='book'..i
        catalog.books[i]={schemaVersion=2,status='ready',bookId=id,title=id,fileName=id..'.epub',path='books/'..id..'.epub',
            size=1,uploadedAt=Record.iso_timestamp(os.time())}
    end
    remote.put('/apps/fixture/library.json',assert(Catalog.encode(catalog)))
    c.backend:invalidate_link('library.json')
    local primed
    c.backend:download('library.json',function(e,v)assert(not e);primed=v end);assert(primed)
    local diagnostic=require('modules/diagnostics').new{version='test',operation='upload_book',backend='baidu'}
    diagnostic:stage('upload');c.backend.operation_opts.diagnostics=diagnostic
    remote.calls={}
    local result=run(c,'upload_book',context,options);assert(not result.e,result.e and result.e.message)
    assert(#remote.calls==12,'expected 12 warm HTTP requests, got '..#remote.calls)
    local metrics=diagnostic:finish('success')
    assert(metrics.request_count==#remote.calls and metrics.cache_hits.download_link==1)
    assert(#result.value.library.entries==n+1)
    for _,call in ipairs(remote.calls)do assert(call.method~='list','warm upload must not enumerate directories')end
    c.backend:invalidate_link('library.json');remote.calls={}
    diagnostic=require('modules/diagnostics').new{version='test',operation='upload_book',backend='baidu'}
    c.backend.operation_opts.diagnostics=diagnostic
    result=run(c,'upload_book',context,options);assert(not result.e,result.e and result.e.message)
    assert(#remote.calls==14,'expected 14 cold HTTP requests, got '..#remote.calls)
    metrics=diagnostic:finish('success');assert(metrics.request_count==14 and metrics.cache_misses.download_link==1)
    c.backend.operation_opts.diagnostics=nil
    print('Baidu '..n..' books + 10 MiB: warm=12, cold=14 HTTP requests')
end
-- Every browse reads library.json only, with one GET on a valid cached link.
assert(not run(c,'list',options).e);remote.calls={}
assert(not run(c,'list',options).e)
assert(#remote.calls==2 and remote.calls[1].method=='uinfo' and remote.calls[2].method=='/download')
-- Seven-hour cache survives adapter recreation but is isolated by token/account.
local now=os.time()
c.backend.profile.expires_at=now+86400;c.backend.now=function()return now end
c.backend:invalidate_link('library.json')
local function download(api)
    local err,value
    api:download('library.json',function(e,v)err=e;value=v end)
    assert(not err,err and err.message);assert(value)
end
download(c.backend);remote.calls={};download(c.backend);assert(#remote.calls==1)
local another=remote.api();another.now=c.backend.now;another.profile.expires_at=now+86400
remote.calls={};download(another);assert(#remote.calls==1)
now=now+7*3600;remote.calls={};download(c.backend);assert(#remote.calls==2)
-- A stale link gets one refresh and one retry; no infinite retry loop.
local original=remote.transport;local fails=0
c.backend.transport=function(req,done)
    if req.url:find('/download?',1,true) and fails==0 then fails=fails+1;return done(nil,{status=403,body=''})end
    original(req,done)
end
remote.calls={};download(c.backend);assert(fails==1 and #remote.calls==3)
c.backend.transport=original
-- A permanently invalid link retries once, then stops and discards the cache.
c.backend.transport=function(req,done)
    if req.url:find('/download?',1,true) then fails=fails+1;return done(nil,{status=403,body=''})end
    original(req,done)
end
local err;fails=0
c.backend:download('library.json',function(e)err=e end)
assert(err and fails==2 and not c.backend.links['library.json'])
c.backend.transport=original
-- Metadata lookup refreshes an ID invalidated by remote same-path replacement.
download(c.backend)
local old=c.backend.links['library.json']
old.dlink=nil
remote.files['/apps/fixture/library.json'].id='999999999999'
remote.calls={};download(c.backend)
assert(c.backend.links['library.json'].fs_id=='999999999999')
-- Different credentials never reuse the old URL.
local changed=remote.api();changed.profile.access_token='other-token'
local API=require('modules/baidu_api');changed=assert(API:new(changed.profile));changed.transport=remote.transport
remote.calls={};download(changed);assert(#remote.calls==3)
-- Manual inventory discovers vendor-app uploads and preserves the exact path.
local progress_raw=remote.files['/apps/fixture/progress/same.json'].raw
remote.put('/apps/fixture/books/Manual.EPUB','manual epub')
remote.put('/apps/fixture/books/ignored.pdf','pdf')
remote.put('/apps/fixture/books/bad%.epub','bad name')
remote.put('/apps/fixture/books/duplicate.epub','one')
remote.put('/apps/fixture/books/duplicate.EPUB','two')
c.backend:invalidate_link('library.json')
local refreshed=run(c,'list',{reconcile_books=true,schedule=options.schedule})
assert(not refreshed.e,refreshed.e and refreshed.e.message)
assert(refreshed.value.refresh_summary.added==1 and refreshed.value.refresh_summary.skipped==3)
assert(remote.files['/apps/fixture/progress/same.json'].raw==progress_raw)
local imported
for _,entry in ipairs(refreshed.value.entries)do if entry.record.bookId=='Manual'then imported=entry end end
assert(imported and imported.record.path=='books/Manual.EPUB')
local downloaded_manual=run(c,'download_book',imported,options)
assert(not downloaded_manual.e,downloaded_manual.e and downloaded_manual.e.message)
assert(read(downloaded_manual.value.path)=='manual epub')
assert(not run(c,'delete_book',imported,options).e)
assert(not remote.files['/apps/fixture/books/Manual.EPUB'])
-- Malformed authoritative catalog does not trigger a scan/rebuild or overwrite.
remote.put('/apps/fixture/library.json','{');c.backend:invalidate_link('library.json')
local bad=run(c,'upload_book',context,options);assert(bad.e and remote.files['/apps/fixture/library.json'].raw=='{')
print('Baidu name identity, overwrite/progress, catalog-only browsing and seven-hour link cache passed')
