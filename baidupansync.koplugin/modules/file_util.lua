--[[--
Small filesystem helpers shared by the local store and the export directory.

Kept separate from storage.lua so that the atomic-write rule is implemented
once and can be tested directly (spec 8.1: temp file + atomic replace).
]]

local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")

local Errors = require("modules/errors")

local FileUtil = {}

--- Recursive mkdir; succeeds when the directory already exists.
function FileUtil.mkdir_p(path)
    if lfs.attributes(path, "mode") == "directory" then return true end
    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" and parent ~= path then
        local ok, err = FileUtil.mkdir_p(parent)
        if not ok then return nil, err end
    end
    local ok, err = lfs.mkdir(path)
    if not ok and lfs.attributes(path, "mode") ~= "directory" then
        return nil, err
    end
    return true
end

--- Writes `content` to `path` through a same-directory temp file and rename.
-- On POSIX the rename atomically replaces an existing file. On failure the
-- existing target is left untouched.
function FileUtil.write_atomic(path, content)
    local tmp_path = path .. ".tmp"
    local file, open_err = io.open(tmp_path, "wb")
    if not file then
        return nil, Errors.new(Errors.CODES.IO,
            "无法写入临时文件: " .. tostring(open_err))
    end
    local wrote, write_err = file:write(content)
    if wrote then
        pcall(ffiUtil.fsyncOpenedFile, file)
    end
    file:close()
    if not wrote then
        os.remove(tmp_path)
        return nil, Errors.new(Errors.CODES.IO,
            "无法写入文件: " .. tostring(write_err))
    end
    local renamed, rename_err = os.rename(tmp_path, path)
    if not renamed then
        os.remove(tmp_path)
        return nil, Errors.new(Errors.CODES.IO,
            "无法原子替换文件: " .. tostring(rename_err))
    end
    return true
end

--- Reads a whole file, refusing files larger than `max_bytes`.
function FileUtil.read_file(path, max_bytes)
    local attr = lfs.attributes(path)
    if not attr then
        return nil, Errors.new(Errors.CODES.NOT_FOUND, "文件不存在")
    end
    if attr.mode ~= "file" then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT, "路径不是普通文件")
    end
    if max_bytes and attr.size and attr.size > max_bytes then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT,
            "文件超过 " .. tostring(max_bytes) .. " 字节上限")
    end
    local file, open_err = io.open(path, "rb")
    if not file then
        return nil, Errors.new(Errors.CODES.IO,
            "无法读取文件: " .. tostring(open_err))
    end
    local text = file:read("*a")
    file:close()
    if type(text) ~= "string" then
        return nil, Errors.new(Errors.CODES.IO, "无法读取文件")
    end
    return text
end

return FileUtil
