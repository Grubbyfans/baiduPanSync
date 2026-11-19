-- Name identity: no EPUB digest is computed or compared.
local Meta=require('modules/book_metadata')
local E=require('modules/errors')
local M={}
function M.filename(value)
    if type(value)~='string' then return nil,E.new('INVALID_INPUT','书籍文件名无效') end
    local name=Meta.name(value)
    -- Keep the cloud path portable and reject ambiguous sanitization/truncation.
    if not name or name~=value:gsub('%.[Ee][Pp][Uu][Bb]$','.epub') or name:find('%',1,true) then
        return nil,E.new('INVALID_INPUT','文件名含不支持的字符或过长，请先在本机重命名')
    end
    return name
end
function M.id(value)
    local name,e=M.filename(value);if not name then return nil,e end
    local id=name:sub(1,-6)
    if id=='' or id=='.' or id=='..' or id:match('^%s') or id:match('%s$') then
        return nil,E.new('INVALID_INPUT','书名不能为空、点号或含首尾空格')
    end
    return id
end
-- Local filenames already exist on disk; do not sanitize/truncate them using
-- the cloud publication naming policy. Only the final EPUB extension is stripped.
function M.local_id(value)
    if type(value)~='string' or not value:match('%.[Ee][Pp][Uu][Bb]$')
        or value:find('/',1,true) or value:find('\\',1,true) or value:find('%z')
        or not require('modules/progress_record').is_valid_utf8(value) then
        return nil,E.new('INVALID_INPUT','本机 EPUB 文件名无效')
    end
    local id=value:sub(1,-6)
    if id=='' or id=='.' or id=='..' then return nil,E.new('INVALID_INPUT','本机 EPUB 书名无效')end
    return id
end
function M.local_valid(id)
    return type(id)=='string' and M.local_id(id..'.epub')==id
end
function M.valid(id)
    return type(id)=='string' and M.id(id..'.epub')==id
end
return M
