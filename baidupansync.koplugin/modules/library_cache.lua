-- Persistent catalog and thumbnail cache, isolated by backend/account.
local json=require('json')
local Files=require('modules/file_util')
local Hash=require('modules/hash')
local Catalog=require('modules/library_catalog')
local M={};M.__index=M
function M:new(dir)return setmetatable({dir=dir},self)end
function M:path(id)
    if not Hash.is_sha256_hex(id) then return nil end
    return self.dir..'/catalog-'..id..'.json'
end
function M:load(id,root)
    local path=self:path(id);if not path then return nil end
    local raw=Files.read_file(path,Catalog.MAX_BYTES+65536);if not raw then return nil end
    local ok,v=pcall(json.decode,raw)
    if not ok or type(v)~='table' or v.schemaVersion~=2 or v.backend_id~=id
        or type(v.updated_at)~='number' or v.updated_at<0 or v.updated_at>os.time()+86400
        or not Catalog.validate(v.catalog) then return nil end
    local result={catalog=v.catalog,entries={},issues={},unpublished={},backend_id=id,backend=root,updated_at=v.updated_at,cached=true}
    for _,book in ipairs(v.catalog.books) do
        result.entries[#result.entries+1]={record=book,backend_id=id,stat={type='file',size=0},book_stat={type='file',size=book.size}}
    end
    return result
end
function M:save(id,result)
    local path=self:path(id)
    if not path or result.backend_id~=id or not Catalog.validate(result.catalog) then return false end
    local ok,raw=pcall(json.encode,{schemaVersion=2,backend_id=id,updated_at=result.updated_at,catalog=result.catalog})
    if not ok or #raw>Catalog.MAX_BYTES+65536 or not Files.mkdir_p(self.dir) then return false end
    return Files.write_atomic(path,raw)
end
function M:fresh(result,now)
    return result and os.date('%Y-%m-%d',result.updated_at)==os.date('%Y-%m-%d',now or os.time())
end
function M:cover_path(id,record)
    if not self:path(id) or type(record.coverVersion)~='string' then return nil end
    return self.dir..'/cover-'..id..'-'..Hash.sha256_text(record.bookId)..'.json'
end
function M:load_cover(id,record)
    local path=self:cover_path(id,record);if not path then return nil end
    local raw=Files.read_file(path,65536);if not raw then return nil end
    local ok,v=pcall(json.decode,raw)
    if ok and type(v)=='table' and v.version==record.coverVersion and require('modules/book_cover').decode(v.coverPng) then return v.coverPng end
end
function M:save_cover(id,record,cover)
    local path=self:cover_path(id,record)
    if not path or not require('modules/book_cover').decode(cover) or not Files.mkdir_p(self.dir) then return false end
    return Files.write_atomic(path,json.encode({version=record.coverVersion,coverPng=cover}))
end
function M:invalidate(id)local p=self:path(id);if p then os.remove(p)end end
return M
