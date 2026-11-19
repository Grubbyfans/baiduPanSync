--[[--
Cloud reading-progress record, schemaVersion=1 (spec 4.1).

This replaces the Stage A local round-trip record. It requires the full-content
SHA-256 identity:

    book.id == book.contentSha256 == 64 lowercase hex characters

`book.id` is the stable path key; the title is display-only. The `sync` block
carries a display/diagnostic `revision`, a unique `writeId`, the global
`deviceId` snapshot and an ISO-8601 `updatedAt` (device time, never used to
decide which record is newer).

Validation is strict and total: unknown schema versions, missing or extra
identity mismatches, malformed positions and malformed sync blocks are rejected
rather than coerced. `raw_fingerprint()` hashes the original bytes, which is
what conflict detection compares; serialization whitespace counts as a change.
]]

local json = require("json")

local Errors = require("modules/errors")
local Hash = require("modules/hash")

local ProgressRecord = {}

ProgressRecord.SCHEMA_VERSION = 1
ProgressRecord.MAX_BYTES = 64 * 1024
ProgressRecord.MAX_XPOINTER_BYTES = 8 * 1024
ProgressRecord.MAX_TEXT_BYTES = 512
ProgressRecord.MAX_ID_BYTES = 128

local function fail(message)
    return nil, Errors.new(Errors.CODES.INVALID_INPUT, message)
end

--- Strict UTF-8 validator (rejects overlongs, surrogates, > U+10FFFF).
function ProgressRecord.is_valid_utf8(value)
    if type(value) ~= "string" then return false end
    local i, n = 1, #value
    while i <= n do
        local c = value:byte(i)
        if c < 0x80 then
            i = i + 1
        elseif c >= 0xC2 and c <= 0xDF then
            local c2 = value:byte(i + 1)
            if not c2 or c2 < 0x80 or c2 > 0xBF then return false end
            i = i + 2
        elseif c >= 0xE0 and c <= 0xEF then
            local c2, c3 = value:byte(i + 1), value:byte(i + 2)
            if not c2 or not c3 then return false end
            if c2 < 0x80 or c2 > 0xBF or c3 < 0x80 or c3 > 0xBF then return false end
            if c == 0xE0 and c2 < 0xA0 then return false end
            if c == 0xED and c2 > 0x9F then return false end
            i = i + 3
        elseif c >= 0xF0 and c <= 0xF4 then
            local c2, c3, c4 = value:byte(i + 1), value:byte(i + 2), value:byte(i + 3)
            if not c2 or not c3 or not c4 then return false end
            if c2 < 0x80 or c2 > 0xBF or c3 < 0x80 or c3 > 0xBF
                or c4 < 0x80 or c4 > 0xBF then return false end
            if c == 0xF0 and c2 < 0x90 then return false end
            if c == 0xF4 and c2 > 0x8F then return false end
            i = i + 4
        else
            return false
        end
    end
    return true
end

local function has_control(value)
    return value:find("%c") ~= nil or value:find("%z") ~= nil
end

local function is_uint(value)
    return type(value) == "number" and value == math.floor(value) and value >= 0
end

local function is_positive_int(value)
    return type(value) == "number" and value == math.floor(value) and value >= 1
end

local function is_finite(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

function ProgressRecord.is_sha256_hex(value)
    return Hash.is_sha256_hex(value)
end

local function validate_title(value)
    if type(value) ~= "string" or value == "" then
        return fail("book.title must be a non-empty string")
    end
    if #value > ProgressRecord.MAX_TEXT_BYTES then
        return fail("book.title is longer than "
            .. ProgressRecord.MAX_TEXT_BYTES .. " bytes")
    end
    if has_control(value) then
        return fail("book.title contains control characters")
    end
    if not ProgressRecord.is_valid_utf8(value) then
        return fail("book.title is not valid UTF-8")
    end
    return true
end

local function validate_opaque_id(value, field)
    if type(value) ~= "string" or value == "" then
        return fail(field .. " must be a non-empty string")
    end
    if #value > ProgressRecord.MAX_ID_BYTES then
        return fail(field .. " is longer than " .. ProgressRecord.MAX_ID_BYTES .. " bytes")
    end
    if has_control(value) then
        return fail(field .. " contains control characters")
    end
    if not ProgressRecord.is_valid_utf8(value) then
        return fail(field .. " is not valid UTF-8")
    end
    return true
end

local function validate_xpointer(value)
    if type(value) ~= "string" or value == "" then
        return fail("progress.value must be a non-empty string")
    end
    if #value > ProgressRecord.MAX_XPOINTER_BYTES then
        return fail("progress.value is longer than "
            .. ProgressRecord.MAX_XPOINTER_BYTES .. " bytes")
    end
    if value:find("%z") then
        return fail("progress.value must not contain NUL")
    end
    if not ProgressRecord.is_valid_utf8(value) then
        return fail("progress.value is not valid UTF-8")
    end
    return true
end

--- Validates a position object ({type="xpointer", value=..., percent?}).
function ProgressRecord.validate_position(position)
    if type(position) ~= "table" then
        return fail("progress must be an object")
    end
    if position.type ~= "xpointer" then
        return fail("progress.type must be \"xpointer\"")
    end
    local ok, err = validate_xpointer(position.value)
    if not ok then return nil, err end
    if position.percent ~= nil then
        if not is_finite(position.percent) then
            return fail("progress.percent must be a finite number")
        end
        if position.percent < 0 or position.percent > 1 then
            return fail("progress.percent must be within 0..1")
        end
    end
    return true
end

local function validate_updated_at(value)
    if type(value) ~= "string" or #value > 64 or has_control(value) then
        return fail("sync.updatedAt must be a short plain string")
    end
    if not value:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d[+-]%d%d:%d%d$") then
        return fail("sync.updatedAt must be ISO-8601 with a UTC offset")
    end
    return true
end

--- Validates a decoded progress record.
function ProgressRecord.validate(record)
    if type(record) ~= "table" then
        return fail("record must be a JSON object")
    end
    if record.schemaVersion ~= ProgressRecord.SCHEMA_VERSION and record.schemaVersion ~= 2 then
        return nil, Errors.new(Errors.CODES.UNSUPPORTED,
            "unsupported schemaVersion: " .. tostring(record.schemaVersion))
    end

    local book = record.book
    if type(book) ~= "table" then return fail("book must be an object") end
    if record.schemaVersion==2 then
        if not require('modules/book_name').valid(book.id) or book.contentSha256~=nil then
            return fail('invalid name-based book identity')
        end
    elseif not ProgressRecord.is_sha256_hex(book.id) then
        return fail("book.id must be 64 lowercase hex characters")
    end
    if record.schemaVersion~=2 and not ProgressRecord.is_sha256_hex(book.contentSha256) then
        return fail("book.contentSha256 must be 64 lowercase hex characters")
    end
    if record.schemaVersion~=2 and book.id ~= book.contentSha256 then
        return fail("book.id must equal book.contentSha256")
    end
    if book.format ~= "epub" then
        return fail("book.format must be \"epub\"")
    end
    if not is_uint(book.size) then
        return fail("book.size must be a non-negative integer")
    end
    local ok, err = validate_title(book.title)
    if not ok then return nil, err end

    ok, err = ProgressRecord.validate_position(record.progress)
    if not ok then return nil, err end

    local sync = record.sync
    if type(sync) ~= "table" then return fail("sync must be an object") end
    if not is_positive_int(sync.revision) then
        return fail("sync.revision must be a positive integer")
    end
    ok, err = validate_opaque_id(sync.writeId, "sync.writeId")
    if not ok then return nil, err end
    ok, err = validate_opaque_id(sync.deviceId, "sync.deviceId")
    if not ok then return nil, err end
    ok, err = validate_updated_at(sync.updatedAt)
    if not ok then return nil, err end

    return true
end

--- Decodes and validates a record from raw JSON text.
function ProgressRecord.decode(text)
    if type(text) ~= "string" then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT, "record text must be a string")
    end
    if #text > ProgressRecord.MAX_BYTES then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT,
            "record exceeds " .. ProgressRecord.MAX_BYTES .. " bytes")
    end
    local ok, decoded = pcall(json.decode, text)
    if not ok then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT, "record is not valid JSON")
    end
    if type(decoded) ~= "table" then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT, "record must be a JSON object")
    end
    local valid, err = ProgressRecord.validate(decoded)
    if not valid then return nil, err end
    return decoded, nil, text
end

--- Encodes a record after re-validating it.
function ProgressRecord.encode(record)
    local valid, err = ProgressRecord.validate(record)
    if not valid then return nil, err end
    local ok, text = pcall(json.encode, record)
    if not ok or type(text) ~= "string" then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT, "record could not be encoded")
    end
    if #text > ProgressRecord.MAX_BYTES then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT,
            "encoded record exceeds " .. ProgressRecord.MAX_BYTES .. " bytes")
    end
    return text
end

--- SHA-256 of the exact bytes read from a remote record.
function ProgressRecord.raw_fingerprint(text)
    if type(text) ~= "string" then return nil end
    return Hash.sha256_text(text)
end

--- ISO-8601 timestamp with the local UTC offset.
function ProgressRecord.iso_timestamp(now)
    now = now or os.time()
    local local_seconds = os.time(os.date("*t", now))
    local utc_seconds = os.time(os.date("!*t", now))
    local offset = os.difftime(local_seconds, utc_seconds)
    local sign = offset < 0 and "-" or "+"
    offset = math.abs(offset)
    local hours = math.floor(offset / 3600)
    local minutes = math.floor((offset % 3600) / 60)
    return string.format("%s%s%02d:%02d", os.date("%Y-%m-%dT%H:%M:%S", now), sign, hours, minutes)
end

--- Builds a cloud progress record from a capture plus the full identity.
-- @tparam table context {book={title=...}, progress={...}}
-- @tparam table identity {content_sha256=..., size=...}
-- @tparam table opts {revision=positive integer, write_id=string,
--                     device_id=string, now=epoch seconds}
function ProgressRecord.build(context, identity, opts)
    opts = opts or {}
    if type(context) ~= "table" or type(context.book) ~= "table"
        or type(context.progress) ~= "table" then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT, "invalid capture context")
    end
    if type(identity) ~= "table"
        or not (identity.name_based and require("modules/book_name").valid(identity.book_id) or ProgressRecord.is_sha256_hex(identity.content_sha256))
        or not is_uint(identity.size) then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT, "invalid book identity")
    end
    local title = identity.name_based and identity.book_id or context.book.title or context.book.file_name
    local record = {
        schemaVersion = identity.name_based and 2 or ProgressRecord.SCHEMA_VERSION,
        book = {
            id = identity.name_based and identity.book_id or identity.content_sha256,
            title = title,
            format = "epub",
            size = identity.size,
            contentSha256 = identity.content_sha256,
        },
        progress = {
            type = "xpointer",
            value = context.progress.value,
        },
        sync = {
            revision = opts.revision,
            writeId = opts.write_id,
            deviceId = opts.device_id,
            updatedAt = ProgressRecord.iso_timestamp(opts.now),
        },
    }
    if context.progress.percent ~= nil then
        record.progress.percent = context.progress.percent
    end
    local valid, err = ProgressRecord.validate(record)
    if not valid then return nil, err end
    return record
end

return ProgressRecord
