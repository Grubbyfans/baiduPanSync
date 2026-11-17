--[[--
Task state machine (spec 2.2).

Only explicitly allowed transitions are accepted, terminal states cannot be
left, and every transition is recorded for diagnostics. The engine reports
states through `on_state`; a failing reporter never corrupts the machine.

`uncertain` is distinct from `failed`: it means a write may have landed and the
result must be re-checked, never blindly retried or reported as success.
]]

local Errors = require("modules/errors")

local Task = {}
Task.__index = Task

Task.STATES = {
    "idle",
    "preparing",
    "reading_remote",
    "awaiting_confirm",
    "rechecking",
    "downloading",
    "validating",
    "persisting_restore",
    "applying",
    "checking_position",
    "writing",
    "verifying",
    "committing_local",
    "done",
    "failed",
    "cancelled",
    "uncertain",
}

Task.TERMINAL = {
    done = true,
    failed = true,
    cancelled = true,
    uncertain = true,
}

Task.TRANSITIONS = {
    idle = { preparing = true, cancelled = true },
    preparing = { reading_remote = true, writing = true, failed = true, cancelled = true },
    reading_remote = {
        awaiting_confirm = true, rechecking = true, downloading = true,
        failed = true, cancelled = true,
    },
    awaiting_confirm = { rechecking = true, failed = true, cancelled = true },
    rechecking = {
        writing = true, reading_remote = true, persisting_restore = true,
        committing_local = true,
        failed = true, cancelled = true, uncertain = true,
    },
    downloading = { validating = true, failed = true, cancelled = true, uncertain = true },
    validating = { persisting_restore = true, failed = true, cancelled = true },
    persisting_restore = { applying = true, failed = true, cancelled = true },
    applying = {
        checking_position = true, failed = true, cancelled = true, uncertain = true,
    },
    checking_position = {
        committing_local = true, failed = true, uncertain = true, cancelled = true,
    },
    writing = { verifying = true, failed = true, cancelled = true, uncertain = true },
    verifying = { committing_local = true, failed = true, uncertain = true },
    committing_local = { done = true, failed = true, uncertain = true },
    done = {},
    failed = {},
    cancelled = {},
    uncertain = {},
}

--- @tparam table o {kind=string, id=string, on_state=function(state, info)}
function Task:new(o)
    o = o or {}
    local instance = setmetatable({
        kind = o.kind or "unknown",
        id = o.id,
        state = "idle",
        terminal = false,
        history = {},
        on_state = o.on_state,
    }, self)
    instance.history[1] = { state = "idle" }
    return instance
end

function Task:is_terminal()
    return self.terminal
end

function Task:can_transition(next_state)
    if self.terminal then return false end
    local allowed = Task.TRANSITIONS[self.state]
    return allowed ~= nil and allowed[next_state] == true
end

function Task:transition(next_state, info)
    if self.terminal then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT,
            "任务已结束，不能再切换到 " .. tostring(next_state))
    end
    if not self:can_transition(next_state) then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT,
            string.format("非法任务状态转换: %s -> %s", self.state, tostring(next_state)))
    end
    self.state = next_state
    self.terminal = Task.TERMINAL[next_state] == true
    local entry = { state = next_state, info = info }
    self.history[#self.history + 1] = entry
    if self.on_state then
        pcall(self.on_state, next_state, info)
    end
    return true
end

function Task:cancel(reason)
    if self.terminal then return false end
    local ok = self:transition("cancelled", reason)
    return ok == true
end

function Task:get_state()
    return self.state
end

return Task
