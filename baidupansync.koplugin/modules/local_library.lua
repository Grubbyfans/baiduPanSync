local lfs=require('libs/libkoreader-lfs')
local ffi=require('ffi')
local Util=require('ffi/util')
local Async=require('modules/async')
local Errors=require('modules/errors')
local Random=require('modules/random')
local Metadata=require('modules/book_metadata')
pcall(ffi.cdef,'int link(const char *oldpath, const char *newpath);')
local M={}
function M.fail(code,message)error(Errors.new(code,message,{outcome=code=='UNCERTAIN' and 'uncertain' or 'failed'}),0)end
function M.root(value)
    if type(value)~='string' or value=='' then M.fail('INVALID_INPUT','请先在 KOReader 文件管理器设置根目录') end
    local root=Util.realpath(value)
    if not root or lfs.attributes(root,'mode')~='directory' then M.fail('IO','KOReader 根目录不存在或不可访问') end
    return root:gsub('/+$','')=='' and '/' or root:gsub('/+$','')
end
function M.identify(identity,path,opts)
    return Async.call(function(done)identity:identify(path,opts or {},done)end)
end
function M.scan(root,filename,identity,opts)
    if opts.on_scan_start then opts.on_scan_start(root) end
    local results,stack={}, {root}
    local steps=0
    while #stack>0 do
        if opts.is_cancelled and opts.is_cancelled() then M.fail('CANCELLED','已取消本地同名检查') end
        local dir=table.remove(stack)
        local ok,iterator,object=pcall(lfs.dir,dir)
        if not ok then M.fail('IO','无法完整检查目录：'..dir) end
        while true do
            local read,name=pcall(iterator,object)
            if not read then M.fail('IO','目录读取失败，检查不完整：'..dir) end
            if not name then break end
            if name~='.' and name~='..' then
                local path=dir..'/'..name
                local attr=lfs.symlinkattributes(path)
                if not attr then M.fail('IO','检查期间文件消失，请重试：'..path) end
                if attr.mode=='directory' then stack[#stack+1]=path
                elseif attr.mode=='file' and name:match('%.[Ee][Pp][Uu][Bb]$')
                    and Metadata.name(name)==filename then
                    local hashopts={}
                    for k,v in pairs(opts) do hashopts[k]=v end
                    hashopts.use_cache=false
                    local id=M.identify(identity,path,hashopts)
                    results[#results+1]={path=path,sha256=id.content_sha256,size=id.size,mtime=id.mtime}
                end
                steps=steps+1
                if steps%50==0 then
                    Async.await(function(done)(opts.schedule or function(cb)require('ui/uimanager'):scheduleIn(0,cb)end)(done)end)
                end
            end
        end
    end
    if opts.on_scan_finish then opts.on_scan_finish() end
    table.sort(results,function(a,b)return a.path<b.path end)
    return results
end
function M.reserve(directory)
    local token=Async.check(Random.hex(16))
    -- mkdir is exclusive; caller only ever cleans its own directory/file.
    local dir=directory..'/.baidupansync-download-'..token
    if not lfs.mkdir(dir) then M.fail('IO','无法在下载目录创建临时目录，请检查写权限') end
    local path=dir..'/download.part'
    local file=io.open(path,'wb')
    if not file then lfs.rmdir(dir);M.fail('IO','无法创建下载临时文件') end
    file:close()
    return path,dir
end
function M.space(root,size)
    local ok,total,free,available=pcall(Util.df,root)
    -- Older KOReader builds return only total and free bytes. Prefer the
    -- unprivileged available count whenever the newer API supplies it.
    if ok and available==nil then available=free end
    local function valid(value)
        return type(value)=='number' and value==value and value>=0 and value<math.huge
    end
    if not ok or not valid(total) or not valid(available) then
        local reason=not ok and tostring(total) or (type(free)=='string' and free or '空间接口未返回有效数值')
        M.fail('IO','无法确认下载目录剩余空间：'..root..'\n原因：'..reason)
    end
    if available<size+1024*1024 then M.fail('IO','下载目录可用空间不足（含临时文件余量）：'..root) end
end
-- Move only the old EPUB settings files, without parsing or rewriting Lua.
-- All configured KOReader locations are checked before replacing different bytes.
function M.backup_metadata(target)
    local Settings=require('docsettings')
    local hash_enabled=(Settings.isHashLocationEnabled and Settings.isHashLocationEnabled())
        or (G_reader_settings and G_reader_settings:readSetting('document_metadata_folder')=='hash')
    local candidates,seen={},{}
    local locations={'doc','dir'}
    if hash_enabled then locations[#locations+1]='hash' end
    for _,location in ipairs(locations) do
        local dir=Settings:getSidecarDir(target,location)
        if lfs.symlinkattributes(dir,'mode')=='link' then M.fail('CONFLICT','旧书设置目录是符号链接，请使用重命名下载') end
        candidates[#candidates+1]=dir..'/metadata.epub.lua'
        candidates[#candidates+1]=dir..'/metadata.epub.lua.old'
        if location=='doc' then candidates[#candidates+1]=dir..'/'..Util.basename(target)..'.lua' end
    end
    local legacy=Settings:findSidecarFile(target)
    if legacy then candidates[#candidates+1]=legacy;candidates[#candidates+1]=legacy..'.old' end
    if Settings.getHistoryPath then
        local history=Settings:getHistoryPath(target)
        candidates[#candidates+1]=history;candidates[#candidates+1]=history..'.old'
    end
    candidates[#candidates+1]=target..'.kpdfview.lua'
    local plan,moved={},{}
    for _,source in ipairs(candidates) do
        if not seen[source] then
            seen[source]=true
            local st=lfs.symlinkattributes(source)
            if st then
                if st.mode~='file' then M.fail('CONFLICT','旧书设置不是普通文件，请使用重命名下载') end
                plan[#plan+1]={source=source,backup=source:match('^(.*)/[^/]+$')..'/.baidupansync-metadata-backup-'..Async.check(Random.hex(16))..'.lua'}
            end
        end
    end
    for _,entry in ipairs(plan) do
        if not os.rename(entry.source,entry.backup) then
            local restored=true
            for i=#moved,1,-1 do
                if lfs.symlinkattributes(moved[i].source) or not os.rename(moved[i].backup,moved[i].source) then restored=false end
            end
            if not restored then M.fail('UNCERTAIN','旧书设置备份回退未完整确认，请核对：'..moved[1].backup) end
            M.fail('IO','无法备份旧书设置，已停止并恢复已移动的设置')
        end
        moved[#moved+1]=entry
    end
    -- DocSettings caches path->partial hash internally with no public invalidator.
    -- A restart is required before opening different bytes at the same path in
    -- hash-metadata mode; never patch KOReader's internal tables to bypass this.
    moved.restart_required=hash_enabled and true or false
    return moved
end

local function reserve_name(path)
    require('ffi/posix_h')
    local exclusive=jit.os=='OSX' and 2048 or 128
    local fd=ffi.C.open(path,require('bit').bor(ffi.C.O_CREAT,ffi.C.O_WRONLY,exclusive),ffi.cast('mode_t',384))
    if fd<0 then return nil end
    ffi.C.close(fd)
    return lfs.attributes(path)
end
function M.install(temp,target,expected,current_path)
    if current_path and Util.realpath(current_path)==Util.realpath(target) then
        M.fail('CONFLICT','不能覆盖当前打开的书籍，请先关闭文档')
    end
    local now=lfs.symlinkattributes(target)
    local backup
    if expected then
        if not now or now.mode~='file' or now.size~=expected.size or now.modification~=expected.mtime then
            M.fail('CONFLICT','目标文件在下载期间发生变化，请重新确认')
        end
        local stem=Util.basename(target):gsub('%.[Ee][Pp][Uu][Bb]$','')
        while #stem>150 or not require('modules/progress_record').is_valid_utf8(stem) do stem=stem:sub(1,-2) end
        backup=target:match('^(.*)/[^/]+$')..'/'..stem..'.backup-'..Async.check(Random.hex(16))..'.epub'
        if not reserve_name(backup) then M.fail('IO','无法预留旧书备份路径，未覆盖原书') end
        if not os.rename(target,backup) then os.remove(backup);M.fail('IO','无法保留旧书备份，未覆盖原书') end
    elseif now then M.fail('CONFLICT','目标路径已被占用，请重命名后重试') end
    -- Exclusive reservation works on FAT too; link() is not supported there.
    -- External programs must not replace the reservation while publishing.
    local reserved=reserve_name(target)
    if not reserved then
        if backup then
            if not lfs.symlinkattributes(target) then os.rename(backup,target) end
            M.fail('UNCERTAIN','目标路径被占用，旧书已保留（原路径或备份）：'..backup)
        end
        M.fail('CONFLICT','目标路径已被占用，未覆盖文件')
    end
    local current=lfs.symlinkattributes(target)
    if not current or current.mode~='file' or current.size~=0
        or (reserved.ino and current.ino~=reserved.ino) then
        M.fail('UNCERTAIN','发布期间目标路径变化，请核对备份：'..(backup or temp))
    end
    if not os.rename(temp,target) then
        os.remove(target)
        if backup then os.rename(backup,target) end
        M.fail('IO','下载文件发布失败，已尝试恢复旧文件')
    end
    return {path=target,backup=backup}
end
return M
