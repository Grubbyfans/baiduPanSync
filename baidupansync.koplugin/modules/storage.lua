--[[--
Local persistent store (Stage A subset of spec 8 / 8.1).

Stage A only needs the restore point produced before a navigation, but the file
format is already the versioned envelope required by the spec:

    { "schemaVersion": 1, "data": { "last": { ... } } }

Rules implemented here:
- unknown or corrupt state files are never overwritten with empty state;
- writes go to a temporary file in the same directory and are atomically renamed;
- a restore point is only returned when it passes the same position validation
  used for import, so a corrupted file cannot inject an unvalidated XPointer.
]]

local lfs = require("libs/libkoreader-lfs")
local json = require("json")

local Errors = require("modules/errors")
local FileUtil = require("modules/file_util")
local ProgressRecord = require("modules/progress_record")

local LocalStore = {}
LocalStore.__index = LocalStore
LocalStore.SCHEMA_VERSION = 1
LocalStore.STATE_FILE = "restore_points.json"

local function validate_restore_point(rp)
    if type(rp) ~= "table" then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT, "恢复点必须是对象")
    end
    local book = rp.book
    if type(book) ~= "table" then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT, "恢复点缺少书籍信息")
    end
    if type(book.file_path) ~= "string" or book.file_path == "" then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT, "恢复点缺少书籍路径")
    end
    if type(book.size) ~= "number" or book.size < 0
        or book.size ~= math.floor(book.size) then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT, "恢复点书籍大小无效")
    end
    local ok, err = ProgressRecord.validate_position(rp.position)
    if not ok then return nil, err end
    if rp.created_at ~= nil and type(rp.created_at) ~= "string" then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT, "恢复点时间无效")
    end
    return true
end

--- @tparam table o {dir=<required settings dir>}
function LocalStore:new(o)
    o = o or {}
    if type(o.dir) ~= "string" or o.dir == "" then
        error("LocalStore requires a data directory")
    end
    local dir = o.dir:gsub("/+$", "")
    return setmetatable({
        dir = dir,
        file = dir .. "/" .. LocalStore.STATE_FILE,
    }, self)
end

function LocalStore:get_state_path()
    return self.file
end

-- Reads the envelope. Returns a fresh, empty envelope only when the file is
-- genuinely absent; any unreadable, corrupt or future-version file is an error
-- so that callers cannot overwrite it as if it were empty.
function LocalStore:_read_state()
    local attr = lfs.attributes(self.file)
    if not attr then
        return { schemaVersion = LocalStore.SCHEMA_VERSION, data = {} }
    end
    if attr.mode ~= "file" then
        return nil, Errors.new(Errors.CODES.IO, "本地状态路径不是普通文件")
    end
    local file, open_err = io.open(self.file, "rb")
    if not file then
        return nil, Errors.new(Errors.CODES.IO,
            "无法读取本地状态文件: " .. tostring(open_err))
    end
    local text = file:read("*a")
    file:close()
    if type(text) ~= "string" then
        return nil, Errors.new(Errors.CODES.IO, "无法读取本地状态文件")
    end
    local ok, decoded = pcall(json.decode, text)
    if not ok or type(decoded) ~= "table" then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT,
            "本地状态文件已损坏，已保留原文件")
    end
    if decoded.schemaVersion ~= LocalStore.SCHEMA_VERSION then
        return nil, Errors.new(Errors.CODES.UNSUPPORTED,
            "本地状态版本不受支持: " .. tostring(decoded.schemaVersion)
            .. "，已保留原文件")
    end
    if type(decoded.data) ~= "table" then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT,
            "本地状态结构无效，已保留原文件")
    end
    return decoded
end

function LocalStore:_write_state(state)
    local ok, text = pcall(json.encode, state)
    if not ok or type(text) ~= "string" then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT, "本地状态无法编码")
    end
    local dir_ok, dir_err = FileUtil.mkdir_p(self.dir)
    if not dir_ok then
        return nil, Errors.new(Errors.CODES.IO,
            "无法创建本地状态目录: " .. tostring(dir_err))
    end
    local wrote, write_err = FileUtil.write_atomic(self.file, text)
    if not wrote then return nil, write_err end
    return true
end

-- Saves (replacing) the single restore point kept for "undo last restore".
function LocalStore:save_restore_point(rp)
    local valid, err = validate_restore_point(rp)
    if not valid then return nil, err end
    local state, read_err = self:_read_state()
    if not state then return nil, read_err end
    state.data.last = rp
    return self:_write_state(state)
end

-- Returns the restore point, or nil without error when none has been saved.
-- A malformed restore point is an error, not "no restore point".
function LocalStore:get_restore_point()
    local state, read_err = self:_read_state()
    if not state then return nil, read_err end
    local rp = state.data.last
    if rp == nil then return nil end
    local valid, err = validate_restore_point(rp)
    if not valid then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT,
            "恢复点记录无效: " .. (err and err.message or "未知原因"))
    end
    return rp
end

function LocalStore:has_restore_point()
    local rp = self:get_restore_point()
    return rp ~= nil
end

function LocalStore:clear_restore_point()
    local state, read_err = self:_read_state()
    if not state then return nil, read_err end
    if state.data.last == nil then return true end
    state.data.last = nil
    return self:_write_state(state)
end

return LocalStore
