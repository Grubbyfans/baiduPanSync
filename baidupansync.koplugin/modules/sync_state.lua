--[[--
Sync baseline store (spec 2.1 / 4.1 / 8.1).

Baselines are keyed by `backendId + bookId`, never by book alone, so changing
server/root/account cannot reuse another target's revision or overwrite
permission. A baseline records:

- remote_state: "present" | "absent" (an explicit missing marker; a read error
  must never be stored as "absent");
- base_revision and base_remote_fingerprint (SHA-256 of the exact remote bytes);
- optional last_progress_fingerprint (position only, percent excluded);
- optional last_write_id and updated_at.

The file uses the versioned envelope:

    { "schemaVersion": 1, "data": { "baselines": { "<backendId>": { "<bookId>": ... } } } }

Corrupt or future-version files are preserved and reported, never overwritten
with empty state.
]]

local json = require("json")
local lfs = require("libs/libkoreader-lfs")

local Errors = require("modules/errors")
local FileUtil = require("modules/file_util")
local Hash = require("modules/hash")

local SyncState = {}
SyncState.__index = SyncState
SyncState.SCHEMA_VERSION = 1
SyncState.FILE = "sync_state.json"

local function is_hex_id(value)
    return Hash.is_sha256_hex(value)
end

local function is_positive_int(value)
    return type(value) == "number" and value == math.floor(value) and value >= 1
end

local function is_plain_string(value, max_len)
    return type(value) == "string" and #value > 0 and #value <= max_len
        and value:find("%c") == nil and value:find("%z") == nil
end

local function validate_baseline(baseline)
    if type(baseline) ~= "table" then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT, "基线必须是对象")
    end
    if baseline.remote_state ~= "present" and baseline.remote_state ~= "absent" then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT,
            "基线 remote_state 必须为 present 或 absent")
    end
    if baseline.updated_at ~= nil and not is_plain_string(baseline.updated_at, 64) then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT, "基线 updated_at 无效")
    end
    if baseline.remote_state == "present" then
        if not is_positive_int(baseline.base_revision) then
            return nil, Errors.new(Errors.CODES.INVALID_INPUT,
                "基线 base_revision 必须为正整数")
        end
        if not is_hex_id(baseline.base_remote_fingerprint) then
            return nil, Errors.new(Errors.CODES.INVALID_INPUT,
                "基线 base_remote_fingerprint 必须为 64 位小写十六进制")
        end
        if baseline.last_progress_fingerprint ~= nil
            and not is_hex_id(baseline.last_progress_fingerprint) then
            return nil, Errors.new(Errors.CODES.INVALID_INPUT,
                "基线 last_progress_fingerprint 无效")
        end
    end
    if baseline.last_write_id ~= nil
        and not is_plain_string(baseline.last_write_id, 128) then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT, "基线 last_write_id 无效")
    end
    return true
end

function SyncState:new(o)
    o = o or {}
    if type(o.dir) ~= "string" or o.dir == "" then
        error("SyncState requires a directory")
    end
    local dir = o.dir:gsub("/+$", "")
    return setmetatable({
        dir = dir,
        file = dir .. "/" .. SyncState.FILE,
    }, self)
end

function SyncState:get_path()
    return self.file
end

function SyncState:_read()
    local attr = lfs.attributes(self.file)
    if not attr then
        return {
            schemaVersion = SyncState.SCHEMA_VERSION,
            data = { baselines = {} },
        }
    end
    if attr.mode ~= "file" then
        return nil, Errors.new(Errors.CODES.IO, "同步状态路径不是普通文件")
    end
    local text, read_err = FileUtil.read_file(self.file, 1024 * 1024)
    if not text then return nil, read_err end
    local ok, decoded = pcall(json.decode, text)
    if not ok or type(decoded) ~= "table" then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT,
            "同步状态文件已损坏，已保留原文件")
    end
    if decoded.schemaVersion ~= SyncState.SCHEMA_VERSION then
        return nil, Errors.new(Errors.CODES.UNSUPPORTED,
            "同步状态版本不受支持，已保留原文件")
    end
    if type(decoded.data) ~= "table" or type(decoded.data.baselines) ~= "table" then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT,
            "同步状态结构无效，已保留原文件")
    end
    return decoded
end

function SyncState:_write(state)
    local ok, text = pcall(json.encode, state)
    if not ok or type(text) ~= "string" then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT, "同步状态无法编码")
    end
    local mkdir_ok, mkdir_err = FileUtil.mkdir_p(self.dir)
    if not mkdir_ok then
        return nil, Errors.new(Errors.CODES.IO,
            "无法创建同步状态目录: " .. tostring(mkdir_err))
    end
    return FileUtil.write_atomic(self.file, text)
end

local function validate_ids(backend_id, book_id)
    if not is_hex_id(backend_id) then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT,
            "backendId 必须为 64 位小写十六进制")
    end
    if not is_hex_id(book_id) then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT,
            "bookId 必须为 64 位小写十六进制")
    end
    return true
end

--- Returns the baseline or nil when none exists for this backend+book.
function SyncState:get(backend_id, book_id)
    local ok, err = validate_ids(backend_id, book_id)
    if not ok then return nil, err end
    local state, read_err = self:_read()
    if not state then return nil, read_err end
    local by_backend = state.data.baselines[backend_id]
    if type(by_backend) ~= "table" then return nil end
    local baseline = by_backend[book_id]
    if baseline == nil then return nil end
    local valid, baseline_err = validate_baseline(baseline)
    if not valid then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT,
            "已保存的基线无效: " .. baseline_err.message)
    end
    return baseline
end

function SyncState:put(backend_id, book_id, baseline)
    local ok, err = validate_ids(backend_id, book_id)
    if not ok then return nil, err end
    local valid, baseline_err = validate_baseline(baseline)
    if not valid then return nil, baseline_err end
    local state, read_err = self:_read()
    if not state then return nil, read_err end
    state.data.baselines[backend_id] = state.data.baselines[backend_id] or {}
    state.data.baselines[backend_id][book_id] = baseline
    return self:_write(state)
end

function SyncState:delete(backend_id, book_id)
    local ok, err = validate_ids(backend_id, book_id)
    if not ok then return nil, err end
    local state, read_err = self:_read()
    if not state then return nil, read_err end
    local by_backend = state.data.baselines[backend_id]
    if type(by_backend) ~= "table" or by_backend[book_id] == nil then
        return true
    end
    by_backend[book_id] = nil
    if next(by_backend) == nil then
        state.data.baselines[backend_id] = nil
    end
    return self:_write(state)
end

return SyncState
