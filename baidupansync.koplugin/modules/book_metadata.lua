local json=require('json')
local Hash=require('modules/hash')
local Record=require('modules/progress_record')
local Errors=require('modules/errors')
local M={}
-- coverPng is an optional base64 thumbnail. It is decorative: older records
-- remain valid, and an invalid thumbnail falls back to the title in the UI.
-- book_cover bounds bytes and PNG dimensions before handing data to a decoder.
local function invalid()return nil,Errors.new('INVALID_INPUT','书籍发布记录格式或内容身份无效')end
function M.text(s)
    return type(s)=='string' and #s>0 and #s<=512 and not s:find('%c') and Record.is_valid_utf8(s)
end
function M.name(name)
    if not M.text(name) then return nil end
    name=name:gsub('\\','/'):match('([^/]+)$')
    if not name then return nil end
    name=name:gsub('[<>:"|?*]','_'):gsub('%.[Ee][Pp][Uu][Bb]$','')
    while #name>230 do
        name=name:sub(1,-2)
        while #name>0 and not Record.is_valid_utf8(name) do name=name:sub(1,-2) end
    end
    if name=='' or name=='.' or name=='..' then return nil end
    return name..'.epub'
end
local function timestamp(s)
    if type(s)~='string' then return false end
    local y,m,d,h,minute,second,zone=s:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.+)$')
    if not y then return false end
    if tonumber(m)<1 or tonumber(m)>12 or tonumber(d)<1 or tonumber(d)>31
        or tonumber(h)>23 or tonumber(minute)>59 or tonumber(second)>59 then return false end
    if zone=='Z' then return true end
    local zh,zm=zone:match('^[+-](%d%d):(%d%d)$')
    return zh and tonumber(zh)<=23 and tonumber(zm)<=59 or false
end
function M.validate(v)
    if type(v)~='table' or v.schemaVersion~=1 or v.status~='ready' or not Hash.is_sha256_hex(v.bookId)
        or v.contentSha256~=v.bookId or v.path~='books/'..v.bookId..'.epub'
        or type(v.size)~='number' or v.size<0 or v.size~=math.floor(v.size) or v.size>9007199254740991
        or not M.text(v.fileName) or not M.name(v.fileName)
        or (v.displayFileName~=nil and (not M.text(v.displayFileName) or not M.name(v.displayFileName)))
        or not M.text(v.title) or not timestamp(v.uploadedAt)
        or (v.verificationLevel~='size' and v.verificationLevel~='md5' and v.verificationLevel~='sha256') then return invalid() end
    return v
end
function M.decode(raw)
    if type(raw)~='string' or #raw>65536 then return invalid() end
    local ok,v=pcall(json.decode,raw);if not ok then return invalid() end
    if type(v)=='table' and v.schemaVersion~=nil and v.schemaVersion~=1 then return nil,Errors.new('UNSUPPORTED','书籍元数据版本不受支持，请升级插件') end
    return M.validate(v)
end
function M.encode(v)
    local valid,e=M.validate(v);if not valid then return nil,e end
    local raw=json.encode(v);if #raw>65536 then return invalid() end
    return raw
end
function M.filename(v)return M.name(v.displayFileName or v.fileName)end
return M
