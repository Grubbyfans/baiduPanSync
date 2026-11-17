--[[--
Global plugin config (spec 4.1 / 8.1).

The device identity is generated once and stored in `<settings>/baidupansync/
config.json` inside the versioned envelope:

    { "schemaVersion": 1, "data": { "deviceId": "..." } }

A corrupt or future-version config is preserved and reported, never treated as
empty and overwritten. The device id never changes when books are deleted,
backends are switched or authorization is repeated.
]]

local json = require("json")
local lfs = require("libs/libkoreader-lfs")

local Errors = require("modules/errors")
local FileUtil = require("modules/file_util")
local Random = require("modules/random")

local ConfigStore = {}
ConfigStore.__index = ConfigStore
ConfigStore.SCHEMA_VERSION = 1
ConfigStore.FILE = "config.json"

local function sanitize_label(label)
    if type(label) ~= "string" then return "koreader" end
    label = label:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
    label = label:sub(1, 24)
    if label == "" then return "koreader" end
    return label
end

local function valid_device_id(value)
    return type(value) == "string"
        and #value >= 8 and #value <= 128
        and value:match("^[%w%-_%.]+$") ~= nil
end

function ConfigStore:new(o)
    o = o or {}
    if type(o.dir) ~= "string" or o.dir == "" then
        error("ConfigStore requires a directory")
    end
    local dir = o.dir:gsub("/+$", "")
    return setmetatable({
        dir = dir,
        file = dir .. "/" .. ConfigStore.FILE,
    }, self)
end

function ConfigStore:get_path()
    return self.file
end

function ConfigStore:_read()
    local attr = lfs.attributes(self.file)
    if not attr then
        return { schemaVersion = ConfigStore.SCHEMA_VERSION, data = {} }
    end
    if attr.mode ~= "file" then
        return nil, Errors.new(Errors.CODES.IO, "配置路径不是普通文件")
    end
    local text, read_err = FileUtil.read_file(self.file, 64 * 1024)
    if not text then return nil, read_err end
    local ok, decoded = pcall(json.decode, text)
    if not ok or type(decoded) ~= "table" then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT,
            "配置文件已损坏，已保留原文件")
    end
    if decoded.schemaVersion ~= ConfigStore.SCHEMA_VERSION then
        return nil, Errors.new(Errors.CODES.UNSUPPORTED,
            "配置版本不受支持，已保留原文件")
    end
    if type(decoded.data) ~= "table" then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT,
            "配置结构无效，已保留原文件")
    end
    return decoded
end

function ConfigStore:_write(state)
    local ok, text = pcall(json.encode, state)
    if not ok or type(text) ~= "string" then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT, "配置无法编码")
    end
    local mkdir_ok, mkdir_err = FileUtil.mkdir_p(self.dir)
    if not mkdir_ok then
        return nil, Errors.new(Errors.CODES.IO,
            "无法创建配置目录: " .. tostring(mkdir_err))
    end
    return FileUtil.write_atomic(self.file, text)
end

--- Returns the existing device id, or nil (no error) when not generated yet.
function ConfigStore:get_device_id()
    local state, err = self:_read()
    if not state then return nil, err end
    local device_id = state.data.deviceId
    if device_id == nil then return nil end
    if not valid_device_id(device_id) then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT,
            "已保存的设备 ID 无效，已保留原配置")
    end
    return device_id
end

--- Generates and persists the device id once.
-- @tparam table opts {label=string, random_bytes=number}
function ConfigStore:ensure_device_id(opts)
    opts = opts or {}
    local existing, read_err = self:get_device_id()
    if existing then return existing end
    if read_err then return nil, read_err end

    local state = self:_read()
    if not state then return nil, Errors.new(Errors.CODES.IO, "无法读取配置") end
    if state.data.deviceId ~= nil then
        -- A concurrent/duplicate write happened between the checks above.
        if valid_device_id(state.data.deviceId) then return state.data.deviceId end
        return nil, Errors.new(Errors.CODES.INVALID_INPUT, "已保存的设备 ID 无效")
    end

    local hex, random_err = Random.hex(opts.random_bytes or 8)
    if not hex then return nil, random_err end
    local device_id = sanitize_label(opts.label) .. "-" .. hex
    state.data.deviceId = device_id
    local wrote, write_err = self:_write(state)
    if not wrote then return nil, write_err end
    return device_id
end

return ConfigStore
