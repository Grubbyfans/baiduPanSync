-- Name identity: no EPUB digest is computed or compared.
local E=require('modules/errors')
local M={}
-- A cloud filename must also be usable on the supported local filesystems.
function M.cloud_id(value)
    if type(value)~='string' or not value:match('%.[Ee][Pp][Uu][Bb]$') then return nil,E.new('INVALID_INPUT','不是 EPUB 文件名')end
    if not require('modules/progress_record').is_valid_utf8(value) then return nil,E.new('INVALID_INPUT','文件名不是有效 UTF-8')end
    if #value>255 then return nil,E.new('INVALID_INPUT','文件名超过本机下载支持的 255 字节，请在云端重命名')end
    if value:find('[<>:"|?*%%%c]') or value:find('/',1,true) or value:find('\\',1,true) then
        return nil,E.new('INVALID_INPUT','文件名含插件不支持的路径或文件名字符，请在云端重命名')
    end
    local id=value:sub(1,-6)
    if id=='' or id=='.' or id=='..' or id:match('^%s') or id:match('%s$') then return nil,E.new('INVALID_INPUT','书名为空、点号或含首尾空格，请在云端重命名')end
    return id
end
function M.filename(value)
    local id,e=M.cloud_id(value);if not id then return nil,e end
    return id..'.epub'
end
function M.id(value)return M.cloud_id(value)end
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
