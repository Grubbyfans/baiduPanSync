-- Name-based, single-writer cloud orchestration for both backends.
local A=require('modules/async')
local Errors=require('modules/errors')
local Record=require('modules/progress_record')
local Meta=require('modules/book_metadata')
local Name=require('modules/book_name')
local Catalog=require('modules/library_catalog')
local Local=require('modules/local_library')
local Random=require('modules/random')
local Task=require('modules/task')
local json=require('json')
local lfs=require('libs/libkoreader-lfs')
local M={};M.__index=M
local function fail(code,message,outcome)error(Errors.new(code,message,{outcome=outcome}),0)end
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
    local e,raw=A.await(function(cb)self.backend:download(path,cb)end)
    if e then
        if e.code=='NOT_FOUND' then return nil end
        if e.code=='CONFLICT' and path:match('^progress/') and not self:optional_stat('progress') then return nil end
        error(e,0)
    end
    return {raw=raw,record=A.check(decode(raw)),stat={type='file',size=#raw}}
end
function M:guard(context,opts)
    if opts.guard then A.check(opts.guard()) end
    if context then A.check(self.progress:_check_context(context)) end
    if opts.is_cancelled and opts.is_cancelled() then fail('CANCELLED','已取消任务') end
end
function M:identify(context,opts)
    self:guard(context,opts)
    local st=lfs.attributes(context.book.file_path)
    if not st or st.mode~='file' or st.size<1 or st.size>1024*1024*1024 then fail('INVALID_INPUT','书籍必须是可读的 EPUB，最大 1 GiB') end
    return {book_id=A.check(Name.id(context.book.file_name)),size=st.size,mtime=st.modification,name_based=true}
end
function M:confirm(info,opts)
    if not opts.confirm then fail('INVALID_INPUT','此操作需要用户确认') end
    local decision=A.await(function(done)opts.confirm(info,function(choice)done(choice)end)end,{no_timeout=true})
    if not decision or decision=='cancel' or (type(decision)=='table' and decision.mode=='cancel') then fail('CANCELLED','用户取消操作') end
    return decision
end
function M:step(state)
    if self.task.state==state then return end
    A.check(self.task:transition(state))
    if state=='writing' or state=='persisting_restore' then self.mutation_started=true end
end
function M:phase(name,opts)
    if opts.on_phase then pcall(opts.on_phase,name) end
end
function M:run(kind,opts,fn,done)
    local supplied=opts or {};opts={}
    for k,v in pairs(supplied) do opts[k]=v end
    done=done or function()end
    if self.active then return done(Errors.new('CONFLICT','已有云端任务，请先完成或取消')) end
    local stopped=false
    local is_cancelled=opts.is_cancelled
    opts.is_cancelled=function()return stopped or (is_cancelled and is_cancelled())end
    self.active=true;self.cleanup={};self.mutation_started=false;self.task=Task:new{kind=kind,on_state=opts.on_state}
    local task=self.task
    task:transition('preparing')
    A.run(function()
        self:guard(nil,opts)
        if self.backend.kind=='baidu' then self:call('ensureAuthorized') end
        return fn(opts)
    end,function(e,result)
        stopped=true
        for i=#self.cleanup,1,-1 do pcall(self.cleanup[i]) end
        self.active=false
        if e then
            if (kind=='upload_book' or kind=='progress_upload' or kind=='delete_book' or kind=='repair_book' or kind=='cleanup_issue') and task.state=='verifying'
                and not e.definite and e.code~='UNCERTAIN' and e.outcome~='uncertain' then
                e=Errors.new('UNCERTAIN','云端修改已发出但未完整核验：'..e.message,{outcome='uncertain'})
            end
            local state=e.code=='CANCELLED' and 'cancelled' or (e.outcome=='uncertain' or e.code=='UNCERTAIN') and 'uncertain' or 'failed'
            task:transition(state,{code=e.code})
        else task:transition('done');result=result or {};result.task=task end
        done(e,result)
    end,{
        timeout=opts.watchdog_timeout or 3700,
        schedule=opts.watchdog_schedule or function(seconds,cb)require('ui/uimanager'):scheduleIn(seconds,cb)end,
        unschedule=opts.watchdog_unschedule or function(cb)require('ui/uimanager'):unschedule(cb)end,
        error=function()
            return Errors.new(self.mutation_started and 'UNCERTAIN' or 'NETWORK',
                self.mutation_started and '任务等待超时，已停止本次操作；修改结果未知，请重新查询，勿直接重试写入'
                    or '任务等待超时，已停止本次操作，请检查网络后重试',
                {outcome=self.mutation_started and 'uncertain' or 'failed'})
        end,
    })
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
function M:progress_operation(operation,context,opts,done)
    return self:run('progress_'..operation,opts,function(o)
        local identity=self:identify(context,o)
        local path='progress/'..identity.book_id..'.json'
        self:step('reading_remote')
        local remote=self:read(path,Record.decode)
        if remote and (remote.record.schemaVersion~=2 or remote.record.book.id~=identity.book_id) then
            fail('CONFLICT','云端进度书名不匹配')
        end
        if operation=='query' then return {remote=remote,identity=identity,backend=self.backend.root} end
        if operation=='download' and not remote then fail('NOT_FOUND','云端尚无此书阅读进度') end
        self:step('awaiting_confirm')
        self:confirm({kind='progress_'..operation,context=context,remote=remote,
            classification={kind='unchanged'},backend=self.backend.root,identity=identity},o)
        self:step('rechecking');self:guard(context,o)
        if operation=='download' then
            context.book.name_identity=identity.book_id
            context.book.source_backend_id=self.backend.backend_id
            A.call(function(cb)self.progress:apply(context,remote.record.progress,cb,{on_state=function(s)self:step(s)end})end)
            self:step('committing_local')
            return {record=remote.record,applied=true}
        end
        if not remote then self:directory('progress') end
        local record=A.check(Record.build(context,identity,{revision=(remote and remote.record.sync.revision or 0)+1,
            write_id=A.check(Random.hex(16)),device_id=A.check(self.config:ensure_device_id{label=self.device_label}),now=self.now()}))
        self:step('writing')
        self:call('uploadSmallJson',path,A.check(Record.encode(record)),{unconditional=true})
        self:step('verifying')
        self:step('committing_local')
        return {record=record,uploaded=true}
    end,done)
end
function M:index()
    local snapshot=self:read('library.json',Catalog.decode)
    return snapshot and snapshot.record or Catalog.empty(),snapshot~=nil
end
function M:result(index)
    local entries={}
    for _,v in ipairs(index.books) do
        entries[#entries+1]={record=v,backend_id=self.backend.backend_id,
            stat={type='file',size=0},book_stat={type='file',size=v.size}}
    end
    return {entries=entries,issues={},unpublished={},backend=self.backend.root,
        backend_id=self.backend.backend_id,updated_at=self.now(),catalog=index}
end
function M:list(opts,done)
    return self:run('library',opts,function(o)
        self:step('reading_remote')
        local index=self:index();self:guard(nil,o)
        return self:result(index)
    end,done)
end
function M:save_index(index)
    local raw=A.check(Catalog.encode(index))
    self:call('uploadSmallJson','library.json',raw,{unconditional=true})
end
function M:temporary(parent)
    A.check(require('modules/file_util').mkdir_p(parent))
    local path,dir=Local.reserve(parent)
    self.cleanup[#self.cleanup+1]=function()os.remove(path);lfs.rmdir(dir)end
    return path
end
function M:upload_book(context,opts,done)
    return self:run('upload_book',opts,function(o)
        local identity=self:identify(context,o)
        self:step('reading_remote')
        local index,exists=self:index()
        if not exists then self:directory('books');self:directory('covers') end
        self:step('rechecking');self:guard(context,o)
        self:step('writing')
        self:phase('上传 EPUB（同名覆盖，进度保留）',o)
        A.call(function(cb)self.backend:upload('books/'..identity.book_id..'.epub',context.book.file_path,o.on_transfer,cb,
            {precondition={unconditional=true}})end)
        local record={schemaVersion=2,status='ready',bookId=identity.book_id,title=identity.book_id,
            fileName=identity.book_id..'.epub',path='books/'..identity.book_id..'.epub',size=identity.size,
            uploadedAt=Record.iso_timestamp(self.now())}
        local previous=Catalog.find(index,identity.book_id)
        if previous then record.coverPath=previous.coverPath;record.coverVersion=previous.coverVersion end
        local warning
        if o.make_cover then
            local ok,cover=pcall(o.make_cover,context.book.file_path,self:temporary(self.temp_dir))
            if ok and require('modules/book_cover').decode(cover) then
                self:phase('上传书籍封面',o)
                local e=A.await(function(cb)A.run(function()
                    local path='covers/'..identity.book_id..'.json'
                    self:call('uploadSmallJson',path,json.encode({coverPng=cover}),{unconditional=true})
                    record.coverPath=path;record.coverVersion=A.check(Random.hex(16))
                end,cb)end)
                if e then
                    if e.code=='CANCELLED' then error(e,0) end
                    warning='书籍已上传，封面上传失败：'..e.message
                    -- A failed overwrite may have changed the remote cover.
                    if record.coverPath then record.coverVersion=A.check(Random.hex(16)) end
                end
            end
        end
        Catalog.put(index,record)
        self:step('verifying');self:guard(context,o)
        self:phase('发布书库列表',o)
        local ok,e=pcall(self.save_index,self,index)
        if not ok then fail('UNCERTAIN','EPUB 已上传，但书库列表未确认更新；可重新上传同名书补全。'..e.message,'uncertain') end
        self:step('committing_local')
        return {record=record,published=true,library=self:result(index),warning=warning}
    end,done)
end
function M:delete_book(entry,opts,done)
    return self:run('delete_book',opts,function(o)
        if entry.backend_id~=self.backend.backend_id then fail('CONFLICT','书库来自其他后端') end
        local valid=A.check(Meta.validate(entry.record))
        if valid.schemaVersion~=2 then fail('UNSUPPORTED','请清空旧数据后使用新版书库') end
        self:step('reading_remote')
        local index=self:index()
        local record=Catalog.find(index,valid.bookId)
        if not record then fail('NOT_FOUND','书库已无此书，请更新书库') end
        local paths={record.path,'progress/'..record.bookId..'.json'}
        if record.coverPath then paths[#paths+1]=record.coverPath end
        self:step('awaiting_confirm')
        self:confirm({kind='delete_book',backend=self.backend.root,record=record,paths=paths},o)
        self:step('rechecking');self:guard(nil,o);self:step('writing')
        for _,path in ipairs(paths) do
            local e=A.await(function(cb)self.backend:delete(path,{unconditional=true},cb)end)
            if e and e.code~='NOT_FOUND' then fail('UNCERTAIN','删除未全部完成，书库条目保留；可重新删除：'..e.message,'uncertain') end
        end
        Catalog.remove(index,record.bookId)
        self:save_index(index)
        self:step('verifying')
        self:step('committing_local')
        return {record=record,deleted=paths,library=self:result(index)}
    end,done)
end
function M:download_book(entry,opts,done)
    return self:run('download_book',opts,function(o)
        if entry.backend_id~=self.backend.backend_id then fail('CONFLICT','书库来自其他后端') end
        local record=A.check(Meta.validate(entry.record))
        if record.schemaVersion~=2 then fail('UNSUPPORTED','请使用新版书库') end
        local root=Local.root(o.home_dir)
        self:step('reading_remote')
        local filename=record.fileName
        local matches
        if o.local_index then
            local found=o.local_index:find(root,record.bookId)
            matches=found and {found} or {}
        else matches=Local.scan(root,filename,self.identity,o) end
        if #matches>1 then fail('CONFLICT','发现同名本机书籍，请删除重复文件后重新检查本机书籍')end
        local target,expected=root..'/'..filename,nil
        if #matches>0 then
            self:step('awaiting_confirm')
            local decision=self:confirm({kind='download_book',backend=self.backend.root,record=record,filename=filename,candidates=matches,unique_local=o.local_index~=nil},o)
            if type(decision)~='table' then fail('CANCELLED','已取消下载') end
            if decision.mode=='rename' and o.local_index then fail('INVALID_INPUT','同名书籍只允许覆盖已登记位置，不允许另存产生重复')
            elseif decision.mode=='rename' then target=root..'/'..A.check(Name.filename(decision.name))
            elseif decision.mode=='overwrite' then
                for _,v in ipairs(matches) do if v.path==decision.path then target=v.path;expected=v end end
                if not expected then fail('INVALID_INPUT','请选择展示的本地文件') end
            else fail('CANCELLED','已取消下载') end
        end
        self:step('rechecking');self:guard(nil,o)
        if o.get_home and Local.root(o.get_home())~=root then fail('CONFLICT','本机下载根目录已变化') end
        Local.space(target:match('^(.*)/[^/]+$'),record.size)
        local temp=self:temporary(target:match('^(.*)/[^/]+$'))
        self:step('downloading')
        A.call(function(cb)self.backend:download(record.path,temp,o.on_transfer,cb,{max_bytes=record.size})end)
        self:step('validating')
        if lfs.attributes(temp,'size')~=record.size then fail('INVALID_INPUT','下载大小与书库列表不符，请主动更新书库后重试') end
        self:guard(nil,o)
        self:step('committing_local')
        local result=Local.install(temp,target,expected,o.current_path and o.current_path())
        if self.identity then self.identity:invalidate(target) end
        if o.local_index then
            local saved,e=o.local_index:register(root,record.bookId,target)
            if not saved then fail('UNCERTAIN','文件已下载，但本机索引保存失败，请重新检查本机书籍：'..e.message,'uncertain')end
        end
        result.record=record
        return result
    end,done)
end
return M
