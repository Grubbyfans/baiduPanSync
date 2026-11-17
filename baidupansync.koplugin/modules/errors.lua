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

-- Do not echo raw Lua exceptions: socket errors may contain signed URLs/tokens.
-- A source location and fixed category are sufficient to diagnose compatibility.
function Errors.exception(value,stage,writing)
    if Errors.is_error(value) then return value end
    local raw=type(value)=='string' and value or ''
    local file,line=raw:match('([%w_%-]+%.lua):(%d+):')
    local reason=raw:find('nil value',1,true) and '接口或返回值为空'
        or raw:find('module ',1,true) and '运行环境缺少模块'
        or (raw:find('undefined symbol',1,true) or raw:find('missing declaration for symbol',1,true)) and '运行环境缺少系统接口'
        or raw:find('bad argument',1,true) and '接口参数不兼容'
        or '运行时异常'
    return Errors.new(writing and 'UNCERTAIN' or 'IO',(stage or '任务')..'失败：'..reason..
        (file and ('（'..file..':'..line..'）') or '')..'；已停止，请核对状态',
        {outcome=writing and 'uncertain' or 'failed'})
end

--- One-line description for logs; callers must not pass this to the UI unchanged.
function Errors.describe(err)
    if not Errors.is_error(err) then
        return tostring(err)
    end
    return string.format("%s: %s", err.code, err.message)
end

return Errors
