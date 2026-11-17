-- Local acceleration only. Mutations always re-read the selected remote files.
local json=require('json')
local Files=require('modules/file_util')
local Hash=require('modules/hash')
local Meta=require('modules/book_metadata')
local M={MAX_BYTES=16*1024*1024};M.__index=M
local function stat(v)
    return type(v)=='table' and v.type=='file' and type(v.size)=='number' and v.size>=0 and v.size%1==0
        and (v.etag==nil or type(v.etag)=='string' and #v.etag<=1024)
        and (v.version==nil or type(v.version)=='string' and #v.version<=1024)
        and (v.weak_etag==nil or type(v.weak_etag)=='boolean')
end
function M:new(dir)return setmetatable({dir=dir},self)end
function M:path(id)
    if not Hash.is_sha256_hex(id) then return nil end
    return self.dir..'/library-'..id..'.json'
end
function M:load(id,root)
    local path=self:path(id);if not path then return nil end
    local raw=Files.read_file(path,M.MAX_BYTES);if not raw then return nil end
    local ok,v=pcall(json.decode,raw)
    if not ok or type(v)~='table' or v.schemaVersion~=1 or v.backend_id~=id
        or type(v.entries)~='table' or #v.entries>10000 or type(v.updated_at)~='number'
        or v.updated_at<0 or v.updated_at%1~=0 or v.updated_at>os.time()+86400 then return nil end
    local result={backend_id=id,backend=root,entries={},issues={},unpublished={},updated_at=v.updated_at,cached=true}
    local seen={}
    for _,entry in ipairs(v.entries) do
        if type(entry)~='table' or not stat(entry.stat) or not stat(entry.book_stat) then return nil end
        local record=Meta.decode(entry.raw)
        if not record or entry.stat.size~=#entry.raw or record.size~=entry.book_stat.size or seen[record.bookId] then return nil end
        seen[record.bookId]=true
        result.entries[#result.entries+1]={record=record,raw=entry.raw,fingerprint=Hash.sha256_text(entry.raw),
            stat=entry.stat,book_stat=entry.book_stat,backend_id=id}
    end
    -- Orphans are hints only; repair rechecks existence and the exact version.
    if type(v.unpublished)=='table' and #v.unpublished>10000 then return nil end
    for _,entry in ipairs(type(v.unpublished)=='table' and v.unpublished or {}) do
        if type(entry)~='table' or not Hash.is_sha256_hex(entry.book_id) or entry.path~='books/'..entry.book_id..'.epub'
            or not stat(entry.book_stat) or type(entry.size)~='number' or entry.size<=0 or entry.size>1024*1024*1024
            or entry.size~=entry.book_stat.size or seen[entry.book_id] then return nil end
        seen[entry.book_id]=true
        entry.backend_id=id;result.unpublished[#result.unpublished+1]=entry
    end
    result.issues=type(v.issues)=='table' and v.issues or {}
    if #result.issues>10000 then return nil end
    for _,issue in ipairs(result.issues) do
        if type(issue)~='table' or type(issue.path)~='string' or #issue.path>1024
            or type(issue.message)~='string' or #issue.message>2048 then return nil end
    end
    return result
end
function M:save(id,result)
    local path=self:path(id);if not path or result.backend_id~=id then return false end
    local entries,budget={},0
    if #result.entries>10000 then return false end
    for _,entry in ipairs(result.entries) do
        if type(entry.raw)~='string' or not stat(entry.stat) or not stat(entry.book_stat) then return false end
        budget=budget+#entry.raw*2+8192
        if budget>M.MAX_BYTES then return false end -- bound encoding allocations too
        entries[#entries+1]={raw=entry.raw,stat=entry.stat,book_stat=entry.book_stat}
    end
    budget=budget+#(result.unpublished or {})*2048+#(result.issues or {})*4096
    if budget>M.MAX_BYTES then return false end
    local ok,raw=pcall(json.encode,{schemaVersion=1,backend_id=id,updated_at=result.updated_at,
        entries=entries,issues=result.issues,unpublished=result.unpublished})
    if not ok or #raw>M.MAX_BYTES then return false end
    if not Files.mkdir_p(self.dir) then return false end
    return Files.write_atomic(path,raw)
end
function M:invalidate(id)
    local path=self:path(id);if path then os.remove(path) end
end
return M
