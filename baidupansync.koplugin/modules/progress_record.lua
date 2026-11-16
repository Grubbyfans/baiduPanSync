--[[--
Local reading-progress record (Stage A).

This is the local round-trip format used to prove that XPointer capture and
restore work on real devices. It is deliberately NOT the cloud progress protocol
of spec 4.1: Stage A must not implement the full-content SHA-256 identity
(Stage B). Records therefore carry `recordType = "local-progress"`, a size and,
when available, the KOReader partial MD5 as a weak matching clue.

Validation is intentionally strict: unknown schema versions and malformed
fields are rejected instead of being coerced, and importers must not apply a
record that was not verified by `matches_book()`.
]]

local json = require("json")
local Errors = require("modules/errors")

local ProgressRecord = {}

ProgressRecord.SCHEMA_VERSION = 1
ProgressRecord.RECORD_TYPE = "local-progress"
ProgressRecord.MAX_BYTES = 64 * 1024
ProgressRecord.MAX_XPOINTER_BYTES = 8 * 1024
ProgressRecord.MAX_TEXT_BYTES = 512
ProgressRecord.MAX_TIMESTAMP_BYTES = 64

local function fail(message)
    return nil, Errors.new(Errors.CODES.INVALID_INPUT, message)
end

--- Strict UTF-8 validator (rejects overlongs, surrogates, > U+10FFFF).
-- Byte strings in Lua are commonly invalid; do not trust downloaded JSON.
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
            if c == 0xE0 and c2 < 0xA0 then return false end -- overlong
            if c == 0xED and c2 > 0x9F then return false end -- UTF-16 surrogate
            i = i + 3
        elseif c >= 0xF0 and c <= 0xF4 then
            local c2, c3, c4 = value:byte(i + 1), value:byte(i + 2), value:byte(i + 3)
            if not c2 or not c3 or not c4 then return false end
            if c2 < 0x80 or c2 > 0xBF or c3 < 0x80 or c3 > 0xBF
                or c4 < 0x80 or c4 > 0xBF then return false end
            if c == 0xF0 and c2 < 0x90 then return false end -- overlong
            if c == 0xF4 and c2 > 0x8F then return false end -- > U+10FFFF
            i = i + 4
        else
            return false
        end
    end
    return true
end

local function is_control_char_string(value)
    return value:find("%c") ~= nil or value:find("%z") ~= nil
end

local function is_uint(value)
    return type(value) == "number" and value == math.floor(value) and value >= 0
end

local function is_finite_number(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function validate_text(value, field, opts)
    opts = opts or {}
    if type(value) ~= "string" then
        return fail(field .. " must be a string")
    end
    if opts.non_empty ~= false and value == "" then
        return fail(field .. " must not be empty")
    end
    if #value > ProgressRecord.MAX_TEXT_BYTES then
        return fail(field .. " is longer than " .. ProgressRecord.MAX_TEXT_BYTES .. " bytes")
    end
    if is_control_char_string(value) then
        return fail(field .. " contains control characters")
    end
    if not ProgressRecord.is_valid_utf8(value) then
        return fail(field .. " is not valid UTF-8")
    end
    if opts.no_path_separator and (value:find("/") or value:find("\\")) then
        return fail(field .. " must not contain path separators")
    end
    return true
end

local function validate_xpointer(value)
    if type(value) ~= "string" or value == "" then
        return fail("progress.value must be a non-empty string")
    end
    if #value > ProgressRecord.MAX_XPOINTER_BYTES then
        return fail("progress.value is longer than " .. ProgressRecord.MAX_XPOINTER_BYTES .. " bytes")
    end
    if value:find("%z") then
        return fail("progress.value must not contain NUL")
    end
    if not ProgressRecord.is_valid_utf8(value) then
        return fail("progress.value is not valid UTF-8")
    end
    return true
end

--- Validates a progress position object ({type="xpointer", value=..., percent?}).
-- Shared by the local record, the restore-point store and ProgressService so
-- that no layer accepts a position the others would reject.
function ProgressRecord.validate_position(position)
    if type(position) ~= "table" then
        return fail("position must be an object")
    end
    if position.type ~= "xpointer" then
        return fail("position.type must be \"xpointer\"")
    end
    local ok, err = validate_xpointer(position.value)
    if not ok then return nil, err end
    if position.percent ~= nil then
        if not is_finite_number(position.percent) then
            return fail("position.percent must be a finite number")
        end
        if position.percent < 0 or position.percent > 1 then
            return fail("position.percent must be within 0..1")
        end
    end
    return true
end

--- Validates a decoded record table.
-- @treturn boolean|nil true, or nil plus an Errors object
function ProgressRecord.validate(record)
    if type(record) ~= "table" then
        return fail("record must be a JSON object")
    end
    if record.schemaVersion ~= ProgressRecord.SCHEMA_VERSION then
        return nil, Errors.new(Errors.CODES.UNSUPPORTED,
            "unsupported schemaVersion: " .. tostring(record.schemaVersion))
    end
    if record.recordType ~= ProgressRecord.RECORD_TYPE then
        return fail("recordType must be \"" .. ProgressRecord.RECORD_TYPE .. "\"")
    end

    local book = record.book
    if type(book) ~= "table" then return fail("book must be an object") end
    if book.format ~= "epub" then return fail("book.format must be \"epub\"") end
    if not is_uint(book.size) then
        return fail("book.size must be a non-negative integer")
    end
    local ok, err = validate_text(book.fileName, "book.fileName",
        { no_path_separator = true })
    if not ok then return nil, err end
    if book.title ~= nil then
        ok, err = validate_text(book.title, "book.title")
        if not ok then return nil, err end
    end
    if book.partialMd5 ~= nil then
        if type(book.partialMd5) ~= "string"
            or #book.partialMd5 ~= 32
            or not book.partialMd5:match("^[0-9a-f]+$") then
            return fail("book.partialMd5 must be 32 lowercase hex characters")
        end
    end

    local progress = record.progress
    if type(progress) ~= "table" then return fail("progress must be an object") end
    ok, err = ProgressRecord.validate_position(progress)
    if not ok then return nil, err end

    if record.exportedAt ~= nil then
        if type(record.exportedAt) ~= "string"
            or #record.exportedAt == 0
            or #record.exportedAt > ProgressRecord.MAX_TIMESTAMP_BYTES
            or is_control_char_string(record.exportedAt) then
            return fail("exportedAt must be a short plain string")
        end
    end

    return true
end

--- Decodes and validates a record from raw JSON text.
-- @treturn table|nil record
-- @treturn Errors|nil error
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
    return decoded
end

--- Encodes a record after re-validating it.
-- @treturn string|nil JSON text
-- @treturn Errors|nil error
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

--- ISO-8601 timestamp with the local UTC offset, e.g. 2026-11-16T20:10:00+08:00.
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

--- Builds a local record from a ProgressService capture context.
-- @tparam table context {book={...}, progress={...}}
-- @tparam[opt] number now epoch seconds
function ProgressRecord.from_capture(context, now)
    if type(context) ~= "table" or type(context.book) ~= "table"
        or type(context.progress) ~= "table" then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT, "invalid capture context")
    end
    local record = {
        schemaVersion = ProgressRecord.SCHEMA_VERSION,
        recordType = ProgressRecord.RECORD_TYPE,
        book = {
            title = context.book.title,
            fileName = context.book.file_name,
            format = "epub",
            size = context.book.size,
        },
        progress = {
            type = "xpointer",
            value = context.progress.value,
        },
        exportedAt = ProgressRecord.iso_timestamp(now),
    }
    if context.book.partial_md5 then
        record.book.partialMd5 = context.book.partial_md5
    end
    if context.progress.percent ~= nil then
        record.progress.percent = context.progress.percent
    end
    local valid, err = ProgressRecord.validate(record)
    if not valid then return nil, err end
    return record
end

--- Weak local identity check (Stage A only, NOT a content-identity proof).
-- Size must match; partial MD5 is compared when present on both sides; either
-- file name or title must match so that two same-sized books are not merged.
-- @treturn boolean matches
-- @treturn string|nil reason
function ProgressRecord.matches_book(record, book)
    if type(record) ~= "table" or type(record.book) ~= "table"
        or type(book) ~= "table" then
        return false, "invalid"
    end
    if record.book.size ~= book.size then
        return false, "size"
    end
    if record.book.partialMd5 and book.partial_md5
        and record.book.partialMd5 ~= book.partial_md5 then
        return false, "partialMd5"
    end
    local same_name = record.book.fileName == book.file_name
    local same_title = record.book.title ~= nil and book.title ~= nil
        and record.book.title == book.title
    if not same_name and not same_title then
        return false, "name"
    end
    return true
end

return ProgressRecord
