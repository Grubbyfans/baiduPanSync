--[[--
Export directory for the Stage A local progress JSON round-trip.

The directory is plugin-owned (`<settings>/baidupansync/exports`), so import can
list only files this plugin wrote. Users may still copy a JSON file into that
directory manually; every file is re-validated on load, and a record is never
applied without an explicit identity check by the caller.
]]

local lfs = require("libs/libkoreader-lfs")

local Errors = require("modules/errors")
local FileUtil = require("modules/file_util")
local ProgressRecord = require("modules/progress_record")

local ExportStore = {}
ExportStore.__index = ExportStore
ExportStore.MAX_SCAN = 500

function ExportStore:new(o)
    o = o or {}
    if type(o.dir) ~= "string" or o.dir == "" then
        error("ExportStore requires a directory")
    end
    return setmetatable({ dir = o.dir:gsub("/+$", "") }, self)
end

function ExportStore:get_dir()
    return self.dir
end

local function sanitize_name(name)
    name = tostring(name or ""):match("[^/\\]+$") or ""
    name = name:gsub("[^%w%-_%.]", "_")
    if name == "" or name == ".json" then return nil end
    if not name:match("%.json$") then name = name .. ".json" end
    return name
end

local function unique_path(dir, name)
    local path = dir .. "/" .. name
    if not lfs.attributes(path) then return path end
    local stem = name:gsub("%.json$", "")
    local index = 2
    while true do
        local candidate = string.format("%s/%s-%d.json", dir, stem, index)
        if not lfs.attributes(candidate) then return candidate end
        index = index + 1
        if index > 1000 then
            return nil, Errors.new(Errors.CODES.IO, "导出目录中同名文件过多")
        end
    end
end

--- Writes a validated record to the export directory.
-- @tparam table record
-- @tparam[opt] table opts {filename=...}
-- @treturn string|nil absolute path
-- @treturn Errors|nil
function ExportStore:save(record, opts)
    opts = opts or {}
    local text, err = ProgressRecord.encode(record)
    if not text then return nil, err end
    local ok, dir_err = FileUtil.mkdir_p(self.dir)
    if not ok then
        return nil, Errors.new(Errors.CODES.IO,
            "无法创建导出目录: " .. tostring(dir_err))
    end
    local name = sanitize_name(opts.filename)
        or string.format("progress-%s.json", os.date("%Y%m%d-%H%M%S", opts.now))
    local path, path_err = unique_path(self.dir, name)
    if not path then return nil, path_err end
    local wrote, write_err = FileUtil.write_atomic(path, text)
    if not wrote then return nil, write_err end
    return path
end

--- Lists records in the export directory, newest first.
-- Invalid files are returned with `valid = false` and an `error`, so the UI can
-- show them instead of silently hiding a user's file.
-- @tparam[opt] number limit max entries (default 50)
function ExportStore:list(limit)
    limit = limit or 50
    if lfs.attributes(self.dir, "mode") ~= "directory" then
        return {}, nil
    end
    local entries = {}
    local scanned = 0
    local ok_dir, iterator, dir_obj = pcall(lfs.dir, self.dir)
    if not ok_dir then
        return nil, Errors.new(Errors.CODES.IO, "无法读取导出目录")
    end
    for name in iterator, dir_obj do
        if name ~= "." and name ~= ".." and name:match("%.json$") then
            scanned = scanned + 1
            if scanned > ExportStore.MAX_SCAN then
                return nil, Errors.new(Errors.CODES.UNSUPPORTED,
                    "导出目录文件过多，请手动清理")
            end
            local path = self.dir .. "/" .. name
            local attr = lfs.attributes(path)
            if attr and attr.mode == "file" then
                local entry = {
                    path = path,
                    name = name,
                    mtime = attr.modification or 0,
                    size = attr.size or 0,
                }
                local record, err = self:load(path, true)
                if record then
                    entry.valid = true
                    entry.record = record
                else
                    entry.valid = false
                    entry.error = err
                end
                table.insert(entries, entry)
            end
        end
    end
    table.sort(entries, function(a, b)
        if a.mtime == b.mtime then return a.name < b.name end
        return a.mtime > b.mtime
    end)
    while #entries > limit do
        table.remove(entries)
    end
    return entries, nil
end

local function check_path(store, path, skip_dir_check)
    if type(path) ~= "string" or path == "" then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT, "文件路径无效")
    end
    if not skip_dir_check then
        if path:sub(1, #store.dir + 1) ~= store.dir .. "/" then
            return nil, Errors.new(Errors.CODES.INVALID_INPUT, "只能读取导出目录中的文件")
        end
        local relative = path:sub(#store.dir + 2)
        if relative:find("%.%./") or relative:find("/%.%.$") or relative:sub(1, 3) == "../" then
            return nil, Errors.new(Errors.CODES.INVALID_INPUT, "文件路径不允许包含上级目录")
        end
    end
    return true
end

--- Reads raw bytes of a record file. The bytes are what fingerprints hash.
-- @tparam string path must be inside the export directory
-- @tparam[opt] boolean skip_dir_check internal use by list()
function ExportStore:read(path, skip_dir_check)
    local ok, err = check_path(self, path, skip_dir_check)
    if not ok then return nil, err end
    return FileUtil.read_file(path, ProgressRecord.MAX_BYTES)
end

--- Loads and validates a single record.
-- @tparam string path must be inside the export directory
-- @tparam[opt] boolean skip_dir_check internal use by list()
function ExportStore:load(path, skip_dir_check)
    local text, read_err = self:read(path, skip_dir_check)
    if not text then return nil, read_err end
    return ProgressRecord.decode(text)
end

return ExportStore
