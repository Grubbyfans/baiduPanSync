-- Authoritative, lightweight single-writer catalog. No folder scanning fallback.
local json=require('json')
local Meta=require('modules/book_metadata')
local E=require('modules/errors')
local M={MAX_BYTES=4*1024*1024,MAX_BOOKS=10000}
function M.empty()return {schemaVersion=2,books={}}end
local function invalid()return nil,E.new('INVALID_INPUT','书库列表损坏或超出限制；原文件保留，请检查 library.json')end
function M.validate(v)
    if type(v)~='table' then return invalid() end
    if v.schemaVersion~=2 then return nil,E.new('UNSUPPORTED','书库版本不支持；新版不迁移旧数据') end
    if type(v.books)~='table' or #v.books>M.MAX_BOOKS then return invalid() end
    local seen,n={},0
    for k,book in pairs(v.books) do
        n=n+1
        if type(k)~='number' or k%1~=0 or k<1 or k>#v.books or not Meta.validate(book)
            or book.schemaVersion~=2 or seen[book.bookId]
            or (book.coverVersion~=nil and (type(book.coverVersion)~='string' or #book.coverVersion>128))
            or (book.coverPath and not book.coverVersion) then return invalid() end
        seen[book.bookId]=true
    end
    if n~=#v.books then return invalid() end
    return v
end
function M.decode(raw)
    if type(raw)~='string' or #raw>M.MAX_BYTES then return invalid() end
    local ok,v=pcall(json.decode,raw);if not ok then return invalid() end
    return M.validate(v)
end
function M.encode(v)
    local valid,e=M.validate(v);if not valid then return nil,e end
    local ok,raw=pcall(json.encode,v)
    if not ok or #raw>M.MAX_BYTES then return invalid() end
    return raw
end
function M.find(v,id)for _,b in ipairs(v.books)do if b.bookId==id then return b end end end
function M.remove(v,id)for i=#v.books,1,-1 do if v.books[i].bookId==id then table.remove(v.books,i)end end end
function M.put(v,book)M.remove(v,book.bookId);v.books[#v.books+1]=book end
return M
