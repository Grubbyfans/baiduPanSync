-- Persistent name -> one local EPUB path. Scanning is explicit, never on browse.
local A=require('modules/async')
local E=require('modules/errors')
local Files=require('modules/file_util')
local Local=require('modules/local_library')
local Name=require('modules/book_name')
local json=require('json')
local lfs=require('libs/libkoreader-lfs')
local Util=require('ffi/util')
local M={MAX_BYTES=4*1024*1024,MAX_BOOKS=10000};M.__index=M
local function err(code,msg)return E.new(code,msg)end
function M:new(o)return setmetatable({dir=o.dir,file=o.dir..'/local_books.json',blocked=o.dir..'/local_books_conflicts.json'},self)end
local function within(root,path)
    return type(path)=='string' and path:sub(1,#(root=='/' and '/' or root..'/'))==(root=='/' and '/' or root..'/') and not path:find('/%.%./') and not path:find('/%./')
end
function M:load(root)
    local raw,e=Files.read_file(self.file,M.MAX_BYTES)
    if not raw then if e.code=='NOT_FOUND' then return nil end;return nil,e end
    local ok,v=pcall(json.decode,raw)
    if not ok or type(v)~='table' or v.schemaVersion~=1 or type(v.root)~='string' or type(v.books)~='table'
        or type(v.checked_at)~='number' then return nil,err('INVALID_INPUT','本机书籍索引损坏，请点击“检查本机书籍”重建') end
    if v.root~=root then return nil end
    local count=0
    for id,b in pairs(v.books)do
        count=count+1
        if count>M.MAX_BOOKS or not Name.valid(id) or type(b)~='table' or not within(root,b.path)
            or Name.id(b.path:match('([^/]+)$'))~=id or type(b.size)~='number' or b.size<0
            or type(b.mtime)~='number' then return nil,err('INVALID_INPUT','本机书籍索引无效，请重新检查本机书籍') end
    end
    return v
end
function M:save(v)
    local ok,raw=pcall(json.encode,v)
    if not ok or #raw>M.MAX_BYTES then return nil,err('INVALID_INPUT','本机书籍索引超过大小限制')end
    local made,e=Files.mkdir_p(self.dir);if not made then return nil,err('IO',tostring(e))end
    return Files.write_atomic(self.file,raw)
end
function M:require_index(root)
    local conflict,e=Files.read_file(self.blocked,M.MAX_BYTES)
    if conflict then
        local ok,v=pcall(json.decode,conflict)
        if not ok or type(v)~='table' then error(err('INVALID_INPUT','重复书籍记录损坏，请重新检查本机书籍'),0)end
        if v.root==root then error(err('CONFLICT','上次检查发现同名书籍；请删除或重命名重复文件，再点击“检查本机书籍”'),0)end
    elseif e.code~='NOT_FOUND' then error(e,0)end
    local v,le=self:load(root)
    if le then error(le,0)end
    if not v then error(err('INVALID_INPUT','请先点击书库页的“检查本机书籍”，建立当前根目录的唯一书名索引'),0)end
    return v
end
function M:scan(root,opts,done)
    opts=opts or {}
    A.run(function()
        local books,duplicates,stack,steps,count={},{},{root},0,0
        local function guard()
            if opts.is_cancelled and opts.is_cancelled() then error(err('CANCELLED','已取消检查；上次本机索引保留'),0)end
            if opts.get_home and Local.root(opts.get_home())~=root then error(err('CONFLICT','根目录已变化；请重新检查'),0)end
        end
        while #stack>0 do
            guard()
            local dir=table.remove(stack)
            local ok,iterator,object=pcall(lfs.dir,dir)
            if not ok then error(err('IO','无法完整读取目录：'..dir),0)end
            while true do
                local read,name=pcall(iterator,object)
                if not read then error(err('IO','目录读取失败：'..dir),0)end
                if not name then break end
                if name~='.' and name~='..' then
                    local path=(dir=='/' and '' or dir)..'/'..name
                    local st=lfs.symlinkattributes(path)
                    if not st then error(err('IO','检查期间文件不可访问：'..path),0)end
                    if st.mode=='directory' and not name:match('^%.baidupansync%-') and not name:match('%.sdr$') then
                        stack[#stack+1]=path
                    elseif st.mode=='file' and name:match('%.[Ee][Pp][Uu][Bb]$') and not name:match('%.backup%-%x+%.epub$') then
                        local id,ne=Name.id(name);if not id then error(err('INVALID_INPUT',ne.message..'\n文件：'..path),0)end
                        count=count+1;if count>M.MAX_BOOKS then error(err('INVALID_INPUT','本机 EPUB 超过一万本，检查已停止'),0)end
                        if books[id] then
                            duplicates[id]=duplicates[id] or {books[id].path}
                            duplicates[id][#duplicates[id]+1]=path
                        else books[id]={path=path,size=st.size,mtime=st.modification}end
                    end
                    steps=steps+1
                    if steps%50==0 then
                        guard()
                        A.await(function(cb)(opts.schedule or function(fn)require('ui/uimanager'):scheduleIn(0,fn)end)(cb)end)
                    end
                end
            end
        end
        guard()
        if next(duplicates)then
            A.check(Files.mkdir_p(self.dir))
            A.check(Files.write_atomic(self.blocked,json.encode({root=root,duplicates=duplicates})))
            local lines={'发现同名书籍，本次不更新本机索引。请删除或重命名重复文件后重新检查：'}
            local names={};for id in pairs(duplicates)do names[#names+1]=id end;table.sort(names)
            for _,id in ipairs(names)do
                table.sort(duplicates[id]);lines[#lines+1]='\n'..id
                for _,path in ipairs(duplicates[id])do lines[#lines+1]=path end
            end
            error(err('CONFLICT',table.concat(lines,'\n')),0)
        end
        local v={schemaVersion=1,root=root,books=books,checked_at=os.time()}
        A.check(self:save(v))
        if lfs.symlinkattributes(self.blocked) then
            local ok=os.remove(self.blocked);if not ok then error(err('IO','索引已保存，但无法清除重复文件标记，请重试检查'),0)end
        end
        return v
    end,done)
end
function M:find(root,id)
    local v=self:require_index(root)
    local b=v.books[id]
    if not b then return nil end
    local st=lfs.symlinkattributes(b.path)
    if not st then v.books[id]=nil;A.check(self:save(v));return nil end
    -- Refuse links anywhere in the recorded path, including replaced directories.
    if st.mode~='file' or Util.realpath(b.path)~=b.path then error(err('CONFLICT','本机路径已变化，请重新检查：'..b.path),0)end
    return {path=b.path,size=st.size,mtime=st.modification,same=true}
end
function M:register(root,id,path)
    local v=self:require_index(root)
    if not within(root,path) or Name.id(path:match('([^/]+)$'))~=id then return nil,err('INVALID_INPUT','下载登记路径与书名不一致')end
    if v.books[id] and v.books[id].path~=path and lfs.symlinkattributes(v.books[id].path) then
        return nil,err('CONFLICT','同名书籍已登记在其他路径，请重新检查本机书籍')
    end
    local st=lfs.symlinkattributes(path)
    if not st or st.mode~='file' or Util.realpath(path)~=path then return nil,err('INVALID_INPUT','无法登记下载文件')end
    v.books[id]={path=path,size=st.size,mtime=st.modification}
    return self:save(v)
end
function M:delete(root,id,current,expected_path)
    local b=self:find(root,id);if not b then return nil,err('NOT_FOUND','本机文件已不存在，已移除标记')end
    if expected_path and b.path~=expected_path then return nil,err('CONFLICT','本机路径已变化，请重新确认删除')end
    if current and Util.realpath(current)==b.path then return nil,err('CONFLICT','请先关闭当前书籍，再删除本机文件')end
    local ok,e=os.remove(b.path);if not ok then return nil,err('IO','无法删除本机文件：'..tostring(e))end
    local v=self:require_index(root);v.books[id]=nil
    local saved,se=self:save(v)
    if not saved then return nil,err('UNCERTAIN','文件已删除，但本机索引保存失败，请重新检查本机书籍：'..se.message)end
    return {path=b.path}
end
return M
