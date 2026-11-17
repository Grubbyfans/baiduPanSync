-- WebDAV D/E/F orchestration. One immutable backend per service/task.
local A=require('modules/async')
local Errors=require('modules/errors')
local Hash=require('modules/hash')
local Record=require('modules/progress_record')
local Meta=require('modules/book_metadata')
local Conflict=require('modules/conflict')
local Local=require('modules/local_library')
local Random=require('modules/random')
local Task=require('modules/task')
local json=require('json')
local lfs=require('libs/libkoreader-lfs')
local M={};M.__index=M
local function fail(code,message,outcome)error(Errors.new(code,message,{outcome=outcome}),0)end
local function same(a,b)
    return (not a and not b) or (a and b and a.fingerprint==b.fingerprint and a.stat.etag==b.stat.etag
        and a.stat.version==b.stat.version)
end
function M:new(o)
    o.backend.progress_dir=o.temp_dir
    return setmetatable({backend=o.backend,identity=o.identity,progress=o.progress,state=o.state,
        config=o.config,temp_dir=o.temp_dir,now=o.now or os.time,device_label=o.device_label or 'koreader'},self)
end
function M:call(method,...)
    local args,n={...},select('#',...)
    return A.call(function(done)
        args[n+1]=done
        self.backend[method](self.backend,unpack(args,1,n+1))
    end)
end
function M:optional_stat(path)
    local e,v=A.await(function(done)self.backend:stat(path,done)end)
    if e and e.code~='NOT_FOUND' then error(e,0) end
    return not e and v or nil
end
function M:read(path,decode)
    local before=self:optional_stat(path)
    if not before then return nil end
    if before.type~='file' or not before.size or before.size>65536 then fail('INVALID_INPUT','远端 JSON 类型或大小无效：'..path) end
    local raw=self:call('download',path)
    local value=A.check(decode(raw))
    local after=self:optional_stat(path)
    if not after or before.etag~=after.etag or before.version~=after.version or before.size~=after.size then fail('CONFLICT','读取时远端记录发生变化，请重试') end
    return {raw=raw,record=value,stat=after,fingerprint=Hash.sha256_text(raw)}
end
function M:guard(context,opts)
    if opts.guard then A.check(opts.guard()) end
    if context then A.check(self.progress:_check_context(context)) end
    if opts.is_cancelled and opts.is_cancelled() then fail('CANCELLED','已取消任务') end
end
function M:identify(context,opts)
    self:guard(context,opts)
    local identity=Local.identify(self.identity,context.book.file_path,opts)
    self:guard(context,opts)
    if identity.size~=context.book.size or (context.book.mtime and identity.mtime~=context.book.mtime) then
        fail('CONFLICT','捕获位置后书籍内容发生变化，请重试')
    end
    return identity
end
function M:confirm(info,opts)
    if not opts.confirm then fail('INVALID_INPUT','此操作需要用户确认') end
    local decision=A.await(function(done)opts.confirm(info,function(choice)done(choice)end)end)
    if not decision or decision=='cancel' or (type(decision)=='table' and decision.mode=='cancel') then fail('CANCELLED','用户取消操作') end
    return decision
end
function M:step(state)
    if self.task.state==state then return end
    A.check(self.task:transition(state))
end
function M:phase(name,opts)
    if opts.on_phase then pcall(opts.on_phase,name) end
end
function M:run(kind,opts,fn,done)
    opts=opts or {};done=done or function()end
    if self.active then return done(Errors.new('CONFLICT','已有云端任务，请先完成或取消')) end
    self.active=true;self.cleanup={};self.task=Task:new{kind=kind,on_state=opts.on_state}
    local task=self.task
    task:transition('preparing')
    A.run(function()
        self:guard(nil,opts)
        if self.backend.kind=='baidu' then self:call('ensureAuthorized') end
        return fn(opts)
    end,function(e,result)
        for i=#self.cleanup,1,-1 do pcall(self.cleanup[i]) end
        self.active=false
        if e then
            if (kind=='upload_book' or kind=='progress_upload' or kind=='delete_book' or kind=='repair_book') and task.state=='verifying'
                and e.code~='UNCERTAIN' and e.outcome~='uncertain' then
                e=Errors.new('UNCERTAIN','云端修改已发出但未完整核验：'..e.message,{outcome='uncertain'})
            end
            local state=e.code=='CANCELLED' and 'cancelled' or (e.outcome=='uncertain' or e.code=='UNCERTAIN') and 'uncertain' or 'failed'
            task:transition(state,{code=e.code})
        else task:transition('done');result=result or {};result.task=task end
        done(e,result)
    end)
end
function M:directory(path)
    local st=self:optional_stat(path)
    if st then if st.type~='directory' then fail('CONFLICT','云端路径不是目录：'..path) end;return end
    local e=A.await(function(done)self.backend:mkdir(path,done)end)
    if e then
        local actual=self:optional_stat(path)
        if not actual or actual.type~='directory' then error(e,0) end
    end
end
function M:ready(require_delete,allow_best_effort)
    if self.backend.kind=='baidu' then
        if require_delete then fail('UNSUPPORTED','百度未验证原子条件删除，不能覆盖其他内容的云端条目，请选择重命名') end
        return false
    end
    if self.backend.conditional_verified and (not require_delete or self.backend.conditional_delete_verified) then return end
    local e=A.await(function(done)require('modules/dav_probe').run(self.backend,done)end)
    if e then
        if allow_best_effort and e.code=='UNSUPPORTED' then return false end
        error(e,0)
    end
    if require_delete and not self.backend.conditional_delete_verified then fail('UNSUPPORTED','服务未通过条件删除验证，请使用重命名保留两本书') end
end
function M:condition(snapshot)
    if self.backend.optimistic_versions then
        return snapshot and {version=snapshot.stat.version} or {absent=true}
    end
    if not self.backend.conditional_verified then return nil end
    if not snapshot then return {absent=true} end
    if not snapshot.stat.etag or snapshot.stat.weak_etag then fail('UNSUPPORTED','远端没有可用的强版本标记') end
    return {etag=snapshot.stat.etag}
end
function M:commit(identity,snapshot)
    self:step('committing_local')
    local v=snapshot.record
    local ok,e=self.state:put(self.backend.backend_id,identity.book_id,{
        remote_state='present',base_revision=v.sync.revision,base_remote_fingerprint=snapshot.fingerprint,
        last_progress_fingerprint=Conflict.position_fingerprint(v.progress),last_write_id=v.sync.writeId,updated_at=v.sync.updatedAt,
    })
    if not ok then fail('UNCERTAIN','远端/阅读位置已确认，但本地基线保存失败：'..e.message,'uncertain') end
end
function M:progress_operation(operation,context,opts,done)
    return self:run('progress_'..operation,opts,function(o)
        local identity=self:identify(context,o)
        local path='progress/'..identity.book_id..'.json'
        self:step('reading_remote')
        local function read()
            local snapshot=self:read(path,Record.decode)
            if snapshot and (snapshot.record.book.id~=identity.book_id or snapshot.record.book.size~=identity.size) then
                fail('CONFLICT','云端进度不属于当前书籍的完整内容身份')
            end
            return snapshot
        end
        if operation=='upload' then
            self:ready(false,true);self:directory('progress')
        end
        local baseline
        if operation~='query' then
            local be
            baseline,be=self.state:get(self.backend.backend_id,identity.book_id)
            if be then error(be,0) end
        end
        for attempt=1,3 do
            local remote=read()
            if operation=='query' then return {remote=remote,identity=identity,backend=self.backend.root} end
            if operation=='download' and not remote then fail('NOT_FOUND','云端尚无此书阅读进度') end
            local classification=Conflict.classify(baseline,remote and remote.fingerprint,remote and remote.record.sync.revision)
            local progress_precondition
            if self.backend.conditional_verified then
                if not remote then progress_precondition={absent=true}
                elseif remote.stat.etag and not remote.stat.weak_etag then progress_precondition={etag=remote.stat.etag} end
            end
            if self.backend.optimistic_versions then progress_precondition=self:condition(remote) end
            self:step('awaiting_confirm')
            self:confirm({kind='progress_'..operation,context=context,remote=remote,classification=classification,
                backend=self.backend.root,identity=identity,best_effort=operation=='upload'
                    and (not progress_precondition or self.backend.optimistic_versions==true)},o)
            self:step('rechecking');self:guard(context,o)
            local checked=self:identify(context,o)
            if checked.book_id~=identity.book_id then fail('CONFLICT','书籍在确认期间发生变化') end
            local latest=read()
            if same(remote,latest) then
                if operation=='download' then
                    context.book.content_sha256=identity.content_sha256
                    context.book.source_backend_id=self.backend.backend_id
                    A.call(function(cb)self.progress:apply(context,remote.record.progress,cb,{on_state=function(s)self:step(s)end})end)
                    self:commit(identity,remote)
                    return {record=remote.record,applied=true}
                end
                local current=context
                if remote and not Conflict.needs_navigation(current.progress,remote.record.progress) then
                    self:commit(identity,remote);return {record=remote.record,unchanged=true}
                end
                local record=A.check(Record.build(current,identity,{revision=(remote and remote.record.sync.revision or 0)+1,
                    write_id=A.check(Random.hex(16)),device_id=A.check(self.config:ensure_device_id{label=self.device_label}),now=self.now()}))
                local raw=A.check(Record.encode(record))
                self:step('writing')
                local write_err=A.await(function(cb)self.backend:uploadSmallJson(path,raw,progress_precondition,cb)end)
                if not write_err then
                    self:step('verifying')
                    local verified=read()
                    if not verified or verified.raw~=raw then fail('UNCERTAIN','上传后回读不符，未更新基线','uncertain') end
                    self:commit(identity,verified)
                    return {record=record,uploaded=true}
                elseif write_err.code~='CONFLICT' then error(write_err,0) end
            end
            self:step('reading_remote') -- confirmation never carries over to another version
        end
        fail('CONFLICT','远端连续变化，请稍后重新同步')
    end,done)
end
function M:all_entries(path)
    local entries,continuation={},nil
    local seen,paths={},{}
    repeat
        local page=self:call('list',path,continuation)
        for _,entry in ipairs(page.entries) do
            if paths[entry.path] then fail('CONFLICT','远端目录分页出现重复条目，请刷新书库重试') end
            paths[entry.path]=true;entries[#entries+1]=entry
        end
        if #entries>10000 then fail('INVALID_INPUT','远端目录超过一万条记录，检查未完成，请整理后重试') end
        continuation=page.continuation
        if continuation then
            if seen[continuation] then fail('CONFLICT','远端目录枚举出现重复分页，已停止') end
            seen[continuation]=true
        end
    until not continuation
    return entries
end
local function version_matches(a,b)
    if not a or not b or a.type~=b.type or a.size~=b.size then return false end
    if a.version and b.version then return a.version==b.version end
    return a.etag and a.etag==b.etag and not a.weak_etag and not b.weak_etag and a.etag:sub(1,2)~='W/' or false
end
function M:listing(cached)
    local books=self:optional_stat('books/')
    local metadata=self:optional_stat('metadata/')
    local result,issues,unpublished={},{},{}
    if not books and not metadata then return result,issues,unpublished end
    local candidates,present,reusable={},{},{}
    if cached and cached.backend_id==self.backend.backend_id then
        for _,entry in ipairs(cached.entries or {}) do reusable[entry.record.bookId]=entry end
    end
    if books then
        if books.type~='directory' then fail('CONFLICT','books 不是目录') end
        for _,entry in ipairs(self:all_entries('books/')) do candidates[entry.path]=entry end
    end
    if metadata then
        if metadata.type~='directory' then fail('CONFLICT','metadata 不是目录') end
        for _,entry in ipairs(self:all_entries('metadata/')) do
            local id=entry.path:match('^metadata/([0-9a-f]+)%.json$')
            if id then present[id]=true end
            if id and #id==64 and entry.type=='file' then
                -- Malformed records are explicit issues, never normal downloads.
                local e,snapshot
                if reusable[id] and version_matches(reusable[id].stat,entry) then snapshot=reusable[id]
                else e,snapshot=A.await(function(cb)
                    A.run(function()return self:read(entry.path,Meta.decode)end,cb)
                end) end
                if e then
                    if e.code~='INVALID_INPUT' and e.code~='UNSUPPORTED' then error(e,0) end
                    issues[#issues+1]={path=entry.path,message=e.message}
                elseif not snapshot or snapshot.record.bookId~=id then
                    issues[#issues+1]={path=entry.path,message='发布记录身份与文件名不一致'}
                else
                    local book=candidates[snapshot.record.path]
                    if book and book.type=='file' and book.size==snapshot.record.size then
                        snapshot.book_stat=book;result[#result+1]=snapshot
                    else issues[#issues+1]={path=entry.path,message='书籍缺失或大小不一致'} end
                end
            elseif entry.type=='file' then issues[#issues+1]={path=entry.path,message='无法识别的发布记录'}
            elseif id then issues[#issues+1]={path=entry.path,message='发布记录不是文件'} end
        end
    end
    for path,book in pairs(candidates) do
        local id=path:match('^books/([0-9a-f]+)%.epub$')
        if id and #id==64 and not present[id] and book.type=='file' and book.size>0 and book.size<=1024*1024*1024 then
            unpublished[#unpublished+1]={book_id=id,path=path,size=book.size,book_stat=book,backend_id=self.backend.backend_id}
        end
    end
    table.sort(unpublished,function(a,b)return a.book_id<b.book_id end)
    table.sort(result,function(a,b)return Meta.filename(a.record)<Meta.filename(b.record)end)
    return result,issues,unpublished
end
function M:list(opts,done)
    return self:run('library',opts,function(o)
        self:step('reading_remote')
        local entries,issues,unpublished=self:listing(o.cached_result);self:guard(nil,o)
        for _,entry in ipairs(entries) do entry.backend_id=self.backend.backend_id end
        return {entries=entries,issues=issues,unpublished=unpublished,backend=self.backend.root,
            backend_id=self.backend.backend_id,updated_at=self.now()}
    end,done)
end
function M:temporary(parent)
    A.check(require('modules/file_util').mkdir_p(parent))
    local path,dir=Local.reserve(parent)
    self.cleanup[#self.cleanup+1]=function()os.remove(path);lfs.rmdir(dir)end
    return path
end
function M:verify_remote_book(identity,path,opts)
    self:step('verifying')
    local stage='准备回读临时文件'
    self:phase(stage,opts)
    local e,verified_temp=A.await(function(done)A.run(function()
        local temp=self:temporary(self.temp_dir)
        stage='检查回读目录剩余空间'
        self:phase(stage,opts)
        Local.space(self.temp_dir,identity.size)
        stage='从云端回读 EPUB'
        self:phase(stage,opts)
        A.call(function(cb)self.backend:download(path,temp,opts.on_transfer,cb,{max_bytes=identity.size,
            progress_title='正在校验已上传书籍',wait_message='正在回读云端 EPUB 并校验完整内容（点击可取消）…'})end)
        stage='核对整书 SHA-256'
        self:phase(stage,opts)
        local hashopts={use_cache=false,schedule=opts.schedule,is_cancelled=opts.is_cancelled,
            on_progress=opts.on_progress,on_hash_start=opts.on_hash_start,on_hash_finish=opts.on_hash_finish}
        local actual=Local.identify(self.identity,temp,hashopts)
        if actual.book_id~=identity.book_id or actual.size~=identity.size then fail('CONFLICT','已存在的云端 EPUB 与路径摘要不符，拒绝补写发布记录') end
        return temp
    end,done)end)
    if e then
        fail('UNCERTAIN','云端 EPUB 已存在，但整书校验未完成，本次书库发布已停止。\n阶段：'..stage..
            '\n位置：'..self.backend.root..' / '..path..'\n原因：'..e.message..
            '\n修复原因后，可从书库“修复未发布书籍”重试，或再次上传并选择“检查并补全发布”。无需删除云端 EPUB。','uncertain')
    end
    return verified_temp
end
function M:upload_book(context,opts,done)
    return self:run('upload_book',opts,function(o)
        o.use_cache=false
        local identity=self:identify(context,o)
        self:step('reading_remote');self:ready();self:directory('books');self:directory('metadata')
        local entries,issues=self:listing()
        if #issues>0 then fail('CONFLICT','云端发布记录不完整，无法可靠检查同名：'..issues[1].path) end
        local filename=A.check(Meta.name(context.book.file_name))
        local collisions,own={},nil
        for _,entry in ipairs(entries) do
            if entry.record.bookId==identity.book_id then own=entry end
            if Meta.filename(entry.record)==filename or entry.record.bookId==identity.book_id then
                collisions[#collisions+1]=entry
            end
        end
        local book_path='books/'..identity.book_id..'.epub'
        local meta_path='metadata/'..identity.book_id..'.json'
        local existing_book=self:optional_stat(book_path)
        local selected
        if #collisions>0 or (existing_book and not own) then
            self:step('awaiting_confirm')
            local decision=self:confirm({kind='upload_book',backend=self.backend.root,identity=identity,filename=filename,
                candidates=collisions,recovery=existing_book and not own,no_replace_other=self.backend.kind=='baidu'},o)
            if type(decision)~='table' then fail('INVALID_INPUT','无效的书籍处理选择') end
            if decision.mode=='skip' then return {skipped=true} end
            if decision.mode=='rename' then
                filename=A.check(Meta.name(decision.name))
                for _,entry in ipairs(entries) do
                    if Meta.filename(entry.record)==filename and entry.record.bookId~=identity.book_id then
                        fail('CONFLICT','重命名后仍有同名书籍，请选择其他名称')
                    end
                end
            elseif decision.mode=='overwrite' then
                for _,entry in ipairs(collisions) do if entry.record.bookId==decision.book_id then selected=entry end end
                if not selected and not (existing_book and not own and decision.book_id==identity.book_id) then
                    fail('INVALID_INPUT','必须选择本次展示的目标书籍')
                end
            else fail('INVALID_INPUT','无效的书籍处理选择') end
            self:step('rechecking')
        else self:step('rechecking') end
        if selected and selected.record.bookId~=identity.book_id then self:ready(true) end
        self:guard(context,o)
        local checked=self:identify(context,o)
        if checked.book_id~=identity.book_id then fail('CONFLICT','源书籍内容已变化') end
        local current_entries,current_issues=self:listing()
        if #current_issues>0 then fail('CONFLICT','确认后云端书库变得不完整') end
        -- Detect newly created same-name entries before publishing anything.
        local known={};for _,entry in ipairs(entries) do known[entry.record.bookId]=entry end
        for _,entry in ipairs(current_entries) do
            if Meta.filename(entry.record)==filename and (not known[entry.record.bookId] or not same(entry,known[entry.record.bookId])) then
                fail('CONFLICT','确认后出现新的同名版本，请重新确认')
            end
        end
        local latest=self:read(meta_path,Meta.decode)
        if not same(own,latest) then fail('CONFLICT','当前内容的发布记录已变化，请重新确认') end
        if selected and not same(selected,self:read('metadata/'..selected.record.bookId..'.json',Meta.decode)) then
            fail('CONFLICT','被替换的远端书籍已变化，请重新确认')
        end
        self:step('writing')
        existing_book=self:optional_stat(book_path)
        if existing_book then self:verify_remote_book(identity,book_path,o)
        else
            A.call(function(cb)self.backend:upload(book_path,context.book.file_path,o.on_transfer,cb,
                {precondition={absent=true},expected_sha256=identity.book_id})end)
            if self.backend.verify_uploaded_content then self:verify_remote_book(identity,book_path,o) end
        end
        self:step('verifying');self:guard(context,o)
        local uploaded=self:optional_stat(book_path)
        if not uploaded or uploaded.type~='file' or uploaded.size~=identity.size then fail('UNCERTAIN','书籍提交大小无法确认，未发布','uncertain') end
        local metadata={schemaVersion=1,status='ready',bookId=identity.book_id,contentSha256=identity.book_id,
            fileName=context.book.file_name,displayFileName=filename,title=context.book.title or context.book.file_name,
            size=identity.size,path=book_path,uploadedAt=Record.iso_timestamp(self.now()),
            verificationLevel=(existing_book or self.backend.verify_uploaded_content) and 'sha256' or 'size'}
        if o.make_cover then
            self:phase('提取书籍封面',o)
            local ok,cover=pcall(o.make_cover,context.book.file_path,self:temporary(self.temp_dir))
            if ok and require('modules/book_cover').decode(cover) then metadata.coverPng=cover end
        end
        -- Re-publishing a title on a device without a cover renderer must not
        -- discard a thumbnail already stored by another device.
        if not metadata.coverPng and own and require('modules/book_cover').decode(own.record.coverPng) then
            metadata.coverPng=own.record.coverPng
        end
        self:guard(context,o)
        local raw=A.check(Meta.encode(metadata))
        self:phase('发布书库记录',o)
        -- The sidecar becomes visible only after the EPUB has been confirmed.
        local e=A.await(function(cb)self.backend:uploadSmallJson(meta_path,raw,self:condition(own),cb)end)
        if e then fail('UNCERTAIN','EPUB 已提交，但发布记录未确认；重新上传可检查补全：'..e.message,'uncertain') end
        local published=self:read(meta_path,Meta.decode)
        if not published or published.raw~=raw then fail('UNCERTAIN','发布记录回读不符，请重新查询','uncertain') end
        if selected and selected.record.bookId~=identity.book_id then
            local old_path='metadata/'..selected.record.bookId..'.json'
            local old=self:read(old_path,Meta.decode)
            if not same(old,selected) then fail('UNCERTAIN','新书已发布，但旧条目变化，替换未完成；两本均保留','uncertain') end
            local de=A.await(function(cb)self.backend:delete(old_path,self:condition(old),cb)end)
            if de or self:optional_stat(old_path) then fail('UNCERTAIN','新书已发布，但旧条目未确认撤下；请核对云端书库','uncertain') end
        end
        self:step('committing_local')
        self:phase('书库发布完成',o)
        return {record=metadata,published=true,previous_content_retained=selected and selected.record.bookId~=identity.book_id}
    end,done)
end
local function same_file(a,b)
    return (not a and not b) or (a and b and a.type==b.type and a.size==b.size
        and a.etag==b.etag and a.version==b.version)
end
function M:repair_book(entry,opts,done)
    return self:run('repair_book',opts,function(o)
        if entry.backend_id~=self.backend.backend_id or not Hash.is_sha256_hex(entry.book_id)
            or entry.path~='books/'..entry.book_id..'.epub' then fail('CONFLICT','修复条目不属于当前后端，请刷新书库') end
        local id=entry.book_id
        local meta_path='metadata/'..id..'.json'
        self:step('reading_remote');self:ready()
        if self:optional_stat(meta_path) then fail('CONFLICT','此书已有发布记录，请刷新书库；不会覆盖已有记录') end
        local book=self:optional_stat(entry.path)
        if not book or book.type~='file' or not book.size or book.size<=0 or book.size>1024*1024*1024
            or not same_file(book,entry.book_stat) then fail('CONFLICT','未发布 EPUB 已变化或超过 1 GiB，请刷新后重新修复') end
        self:step('awaiting_confirm')
        local decision=self:confirm({kind='repair_book',backend=self.backend.root,entry=entry},o)
        if type(decision)=='table' and type(decision.title)=='string' then decision.title=decision.title:match('^%s*(.-)%s*$') end
        if type(decision)~='table' or not Meta.text(decision.title) then fail('INVALID_INPUT','请输入有效的书名') end
        local filename=A.check(Meta.name(decision.title))
        self:step('rechecking');self:guard(nil,o)
        local entries=self:listing()
        for _,other in ipairs(entries) do
            if Meta.filename(other.record)==filename then fail('CONFLICT','云端已有同名书籍，请换一个书名后修复') end
        end
        if self:optional_stat(meta_path) or not same_file(book,self:optional_stat(entry.path)) then fail('CONFLICT','确认期间云端书籍已变化，请刷新书库') end
        self:step('writing')
        local temp=self:verify_remote_book({book_id=id,size=book.size},entry.path,o)
        local record={schemaVersion=1,status='ready',bookId=id,contentSha256=id,path=entry.path,size=book.size,
            fileName=filename,displayFileName=filename,title=decision.title,uploadedAt=Record.iso_timestamp(self.now()),verificationLevel='sha256'}
        if o.make_cover then
            -- Give the optional EPUB renderer a normal extension inside our
            -- exclusive task directory, without installing a local book.
            local epub=temp:gsub('download%.part$','recovered.epub')
            if os.rename(temp,epub) then
                self.cleanup[#self.cleanup+1]=function()os.remove(epub)end
                local ok,cover=pcall(o.make_cover,epub,self:temporary(self.temp_dir))
                if ok and require('modules/book_cover').decode(cover) then record.coverPng=cover end
            end
        end
        self:guard(nil,o)
        if self:optional_stat(meta_path) or not same_file(book,self:optional_stat(entry.path)) then fail('CONFLICT','校验期间云端文件已变化，未发布') end
        self:directory('metadata')
        self:phase('发布修复后的书库记录',o)
        self:call('uploadSmallJson',meta_path,A.check(Meta.encode(record)),self:condition(nil))
        local published=self:read(meta_path,Meta.decode)
        if not published or published.raw~=Meta.encode(record) then fail('UNCERTAIN','修复记录回读不符，请刷新核对','uncertain') end
        self:step('committing_local')
        published.book_stat=book;published.backend_id=self.backend.backend_id
        return {record=record,repaired=true,entry=published}
    end,done)
end
function M:delete_book(entry,opts,done)
    return self:run('delete_book',opts,function(o)
        if entry.backend_id~=self.backend.backend_id then fail('CONFLICT','书库条目来自其他后端，请重新打开当前书库') end
        local valid=A.check(Meta.validate(entry.record))
        self:step('reading_remote')
        if self.backend.kind~='baidu' then self:ready(true) end
        local meta_path='metadata/'..valid.bookId..'.json'
        local remote=self:read(meta_path,Meta.decode)
        if not remote or not same(remote,entry) then fail('CONFLICT','选中的云端书籍已变化，请刷新后重新删除') end
        local paths={valid.path,'progress/'..valid.bookId..'.json',meta_path}
        local snapshots={}
        for _,path in ipairs(paths) do
            local st=self:optional_stat(path)
            if st then
                if st.type~='file' then fail('CONFLICT','目标不是文件，已停止删除：'..path) end
                -- Require a usable version for every file, including the EPUB.
                local condition=self:condition({stat=st})
                if not condition then fail('UNSUPPORTED','此服务无法安全确认删除目标版本') end
                snapshots[path]=st
            end
        end
        if not same_file(entry.book_stat,snapshots[valid.path]) then fail('CONFLICT','云端 EPUB 已变化，请刷新书库后重新删除') end
        self:step('awaiting_confirm')
        self:confirm({kind='delete_book',backend=self.backend.root,record=valid,paths=paths,
            best_effort=self.backend.kind=='baidu'},o)
        self:step('rechecking');self:guard(nil,o)
        for _,path in ipairs(paths) do
            if not same_file(snapshots[path],self:optional_stat(path)) then fail('CONFLICT','确认期间云端文件已变化，未删除：'..path) end
        end
        self:step('writing')
        local deleted={}
        local ok,e=pcall(function()
            for _,path in ipairs(paths) do
                self:guard(nil,o)
                local st=snapshots[path]
                if st then
                    if not same_file(st,self:optional_stat(path)) then fail('CONFLICT','云端文件已变化，停止删除：'..path) end
                    self:call('delete',path,self:condition({stat=st}))
                    deleted[#deleted+1]=path
                    if self:optional_stat(path) then fail('UNCERTAIN','删除后目标仍存在：'..path,'uncertain') end
                end
            end
        end)
        if not ok then
            if #deleted>0 or (type(e)=='table' and (e.code=='UNCERTAIN' or e.outcome=='uncertain')) then
                fail('UNCERTAIN','删除未全部确认，请刷新书库并核对云端文件。已确认删除：'..
                    (#deleted>0 and table.concat(deleted,'、') or '无')..'。原因：'..(type(e)=='table' and e.message or tostring(e)),'uncertain')
            end
            error(e,0)
        end
        self:step('verifying');self:guard(nil,o)
        for _,path in ipairs(paths) do
            if self:optional_stat(path) then fail('UNCERTAIN','删除期间文件重新出现，请刷新核对：'..path,'uncertain') end
        end
        self:step('committing_local')
        return {record=valid,deleted=deleted}
    end,done)
end
function M:download_book(entry,opts,done)
    return self:run('download_book',opts,function(o)
        if entry.backend_id and entry.backend_id~=self.backend.backend_id then fail('CONFLICT','书库条目来自其他后端，请重新打开当前书库') end
        local root=Local.root(o.home_dir)
        local valid=A.check(Meta.validate(entry.record))
        self:step('reading_remote')
        local path='metadata/'..valid.bookId..'.json'
        local remote=self:read(path,Meta.decode)
        if not remote or not same(remote,entry) then fail('CONFLICT','选中的云端发布记录已变化，请刷新书库') end
        local book=self:optional_stat(valid.path)
        if not book or book.type~='file' or book.size~=valid.size then fail('CONFLICT','云端书籍缺失或大小不符') end
        local filename=Meta.filename(valid)
        -- Probe write permission before a potentially expensive recursive scan.
        local permission=self:temporary(root);os.remove(permission)
        local matches=Local.scan(root,filename,self.identity,o)
        local target,expected=root..'/'..filename,nil
        if #matches>0 then
            for _,candidate in ipairs(matches) do candidate.same=candidate.sha256==valid.bookId end
            self:step('awaiting_confirm')
            local decision=self:confirm({kind='download_book',backend=self.backend.root,record=valid,
                filename=filename,candidates=matches},o)
            if type(decision)~='table' then fail('INVALID_INPUT','无效的下载处理选择') end
            if decision.mode=='rename' then target=root..'/'..A.check(Meta.name(decision.name))
            elseif decision.mode=='overwrite' then
                for _,candidate in ipairs(matches) do if candidate.path==decision.path then target=candidate.path;expected=candidate end end
                if not expected then fail('INVALID_INPUT','必须选择本次展示的本地文件') end
            else fail('CANCELLED','已跳过下载') end
        end
        self:step('rechecking');self:guard(nil,o)
        if o.get_home and Local.root(o.get_home())~=root then fail('CONFLICT','KOReader 根目录已变化，请重新下载') end
        if not same(remote,self:read(path,Meta.decode)) then fail('CONFLICT','确认后云端发布版本变化') end
        if not expected and lfs.symlinkattributes(target) then fail('CONFLICT','下载文件名已占用，请重命名') end
        local current=o.current_path and o.current_path()
        if expected and current and require('ffi/util').realpath(current)==require('ffi/util').realpath(target) then
            fail('CONFLICT','请先关闭要覆盖的书籍，再执行下载')
        end
        local parent=target:match('^(.*)/[^/]+$')
        Local.space(parent,valid.size)
        local temp=self:temporary(parent)
        self:step('downloading')
        A.call(function(cb)self.backend:download(valid.path,temp,o.on_transfer,cb,{max_bytes=valid.size})end)
        self:step('validating')
        local hashopts={use_cache=false,schedule=o.schedule,is_cancelled=o.is_cancelled,
            on_progress=o.on_progress,on_hash_start=o.on_hash_start,on_hash_finish=o.on_hash_finish}
        local downloaded=Local.identify(self.identity,temp,hashopts)
        if downloaded.book_id~=valid.bookId or downloaded.size~=valid.size then fail('CONFLICT','下载文件完整摘要或大小不符，已拒绝落盘') end
        if not same(remote,self:read(path,Meta.decode)) then fail('CONFLICT','下载过程中发布记录变化，未安装文件') end
        self:guard(nil,o)
        if o.get_home and Local.root(o.get_home())~=root then fail('CONFLICT','根目录已变化，未安装文件') end
        if expected then
            local old=Local.identify(self.identity,target,hashopts)
            if old.book_id~=expected.sha256 or old.size~=expected.size or old.mtime~=expected.mtime then
                fail('CONFLICT','覆盖目标内容已变化，请重新确认')
            end
        end
        self:step('committing_local')
        local metadata_backups={}
        if expected and expected.sha256~=valid.bookId and o.backup_metadata then
            metadata_backups=o.backup_metadata(target)
        end
        local installed,result=pcall(Local.install,temp,target,expected,o.current_path and o.current_path())
        if not installed then
            if #metadata_backups>0 then
                fail('UNCERTAIN','文件安装未完整确认；旧书设置已保留在：'..metadata_backups[1].backup,'uncertain')
            end
            error(result,0)
        end
        result.metadata_backups=metadata_backups
        result.restart_required=metadata_backups.restart_required
        self.identity:invalidate(target)
        result.record=valid
        return result
    end,done)
end
return M
