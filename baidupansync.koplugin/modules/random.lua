--[[--
Production random tokens (spec 4.1).

writeId, deviceId suffixes and other security-relevant identifiers must come
from an OS random source. Lua's math.random is explicitly not used; if
/dev/urandom is unavailable the call fails instead of degrading silently.
Tests may inject a deterministic generator at the call site.
]]

local Errors = require("modules/errors")

local Random = {}

-- Reads `count` random bytes and returns lowercase hex.
-- @treturn string|nil hex
-- @treturn Errors|nil
function Random.hex(count)
    count = count or 16
    if type(count) ~= "number" or count <= 0 or count ~= math.floor(count) then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT, "随机字节数无效")
    end
    local file = io.open("/dev/urandom", "rb")
    if not file then
        return nil, Errors.new(Errors.CODES.UNSUPPORTED,
            "无法读取系统随机源 /dev/urandom")
    end
    local bytes = file:read(count)
    file:close()
    if type(bytes) ~= "string" or #bytes ~= count then
        return nil, Errors.new(Errors.CODES.IO, "系统随机源返回的数据不完整")
    end
    local out = {}
    for i = 1, #bytes do
        out[i] = string.format("%02x", bytes:byte(i))
    end
    return table.concat(out)
end

--- Token with a short prefix, e.g. writeId or a device suffix.
function Random.token(prefix, count)
    local hex, err = Random.hex(count or 16)
    if not hex then return nil, err end
    return (prefix or "") .. hex
end

function Random.is_hex(value, length)
    return type(value) == "string"
        and (length == nil or #value == length)
        and value:match("^[0-9a-f]+$") ~= nil
end

return Random
