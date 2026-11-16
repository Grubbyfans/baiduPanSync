--[[--
Shared error objects.

Spec 2.2 requires a uniform error structure: {code, message, retryable, outcome}.
`outcome` distinguishes a definite failure from an unknown remote/local state.
This module is intentionally free of KOReader UI dependencies so it can be reused
by storage, adapters and the sync engine in later stages.
]]

local Errors = {}

Errors.CODES = {
    INVALID_INPUT = "INVALID_INPUT",
    AUTH = "AUTH",
    FORBIDDEN = "FORBIDDEN",
    NOT_FOUND = "NOT_FOUND",
    CONFLICT = "CONFLICT",
    UNSUPPORTED = "UNSUPPORTED",
    NETWORK = "NETWORK",
    TLS = "TLS",
    IO = "IO",
    CANCELLED = "CANCELLED",
    UNCERTAIN = "UNCERTAIN",
}

--- Builds a uniform error object.
-- @string code one of Errors.CODES
-- @string message user-readable, must not contain credentials
-- @tparam[opt] table opts {retryable=boolean, outcome="failed"|"uncertain", detail=any}
function Errors.new(code, message, opts)
    opts = opts or {}
    assert(type(code) == "string", "error code must be a string")
    return {
        code = code,
        message = message or code,
        retryable = opts.retryable == true,
        outcome = opts.outcome or "failed",
        detail = opts.detail,
    }
end

--- True for values built by Errors.new (or structurally compatible tables).
function Errors.is_error(value)
    return type(value) == "table" and type(value.code) == "string"
        and type(value.message) == "string"
end

--- One-line description for logs; callers must not pass this to the UI unchanged.
function Errors.describe(err)
    if not Errors.is_error(err) then
        return tostring(err)
    end
    return string.format("%s: %s", err.code, err.message)
end

return Errors
