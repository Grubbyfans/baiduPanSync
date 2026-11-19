-- Confirmed EPUB receipts; replay publishes the catalog only, never the book.
local Files=require('modules/file_util')
local Meta=require('modules/book_metadata')
local Hash=require('modules/hash')
local E=require('modules/errors')
local json=require('json')
local M={};M.__index=M
function M:new(o)return setmetatable({dir=o.dir},self)end
function M:path(id)
    if not Hash.is_sha256_hex(id)then return nil,E.new('INVALID_INPUT','待发布记录后端无效')end
    return self.dir..'/pending-'..id..'.json'
end
function M:load(id)
    local path,e=self:path(id);if not path then return nil,e end
    local raw,re=Files.read_file(path,4*1024*1024)
    if not raw then if re.code=='NOT_FOUND'then return {schemaVersion=1,backend_id=id,items={}}end;return nil,re end
    local ok,v=pcall(json.decode,raw)
    if not ok or type(v)~='table' or v.schemaVersion~=1 or v.backend_id~=id or type(v.items)~='table' then
        return nil,E.new('INVALID_INPUT','待发布记录损坏，原文件保留')
    end
    for name,record in pairs(v.items)do
        if not Meta.validate(record) or record.schemaVersion~=2 or name~=record.bookId then return nil,E.new('INVALID_INPUT','待发布书籍记录无效')end
    end
    return v
end
function M:save(id,v)
    local path,e=self:path(id);if not path then return nil,e end
    local ok,raw=pcall(json.encode,v)
    if not ok or #raw>4*1024*1024 then return nil,E.new('INVALID_INPUT','待发布记录超限')end
    local made,me=Files.mkdir_p(self.dir);if not made then return nil,E.new('IO',tostring(me))end
    return Files.write_atomic(path,raw)
end
function M:put(id,record)
    if not Meta.validate(record) or record.schemaVersion~=2 then return nil,E.new('INVALID_INPUT','待发布书籍记录无效')end
    local v,e=self:load(id);if not v then return nil,e end
    v.items[record.bookId]=record;return self:save(id,v)
end
function M:remove(id,name)
    local v,e=self:load(id);if not v then return nil,e end
    if not v.items[name]then return true end
    v.items[name]=nil;return self:save(id,v)
end
function M:list(id)
    local v,e=self:load(id);if not v then return nil,e end
    local out={};for _,record in pairs(v.items)do out[#out+1]={backend_id=id,record=record}end
    table.sort(out,function(a,b)return a.record.bookId<b.record.bookId end)
    return out
end
return M
