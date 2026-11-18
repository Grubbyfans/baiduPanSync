-- Callback/coroutine bridge, including callbacks which finish synchronously.
local Errors=require('modules/errors')
local M={}
local completions=setmetatable({},{__mode='k'})
local scopes=setmetatable({},{__mode='k'})
function M.has_scope()return scopes[coroutine.running()]~=nil end
local function touch(scope)
    if not scope or scope.cancelled then return end
    scope.unschedule(scope.expire)
    if not scope.paused then scope.schedule(scope.timeout,scope.expire) end
end
-- Register resource cancellation in the current task, including nested backends.
function M.on_cancel(cancel)
    local scope=scopes[coroutine.running()]
    if not scope then return function()end end
    scope.cancellers[cancel]=true
    return function()scope.cancellers[cancel]=nil end
end
function M.await(start,opts)
    local co=coroutine.running()
    local scope=scopes[co]
    if scope and scope.cancelled then return coroutine.yield() end
    local pause=scope and opts and opts.no_timeout
    if pause then scope.paused=true end
    touch(scope)
    local pending,called=true,false
    local result
    start(function(...)
        if called or (scope and scope.cancelled) then return end
        called=true;result={...};result.n=select('#',...)
        if pause then scope.paused=false end
        touch(scope)
        if not pending then M.resume(co,unpack(result,1,result.n)) end
    end)
    pending=false
    if called then return unpack(result,1,result.n) end
    return coroutine.yield()
end
function M.resume(co,...)
    if scopes[co] and scopes[co].cancelled then return end
    local ok,value=coroutine.resume(co,...)
    local done=completions[co]
    if not ok or coroutine.status(co)=='dead' then
        completions[co]=nil
        if done then
            if ok then done(nil,value)
            else done(Errors.exception(value)) end
        end
    end
end
function M.run(fn,done,opts)
    local scope=scopes[coroutine.running()]
    if scope and scope.cancelled then return end
    local co=coroutine.create(fn)
    if opts then
        scope={schedule=opts.schedule,unschedule=opts.unschedule,timeout=opts.timeout or 3700,
            cancellers={},members={}}
        local finished=false
        local function finish(e,v)
            if finished then return end;finished=true
            scope.unschedule(scope.expire)
            for member in pairs(scope.members) do completions[member]=nil end
            scope.members={};scope.cancellers={}
            done(e,v)
        end
        scope.expire=function()
            if finished or scope.paused then return end
            scope.cancelled=true
            -- Stop transports before task cleanup or allowing another operation.
            local cancellations={}
            for cancel in pairs(scope.cancellers) do cancellations[#cancellations+1]=cancel end
            for _,cancel in ipairs(cancellations) do pcall(cancel) end
            finish(opts.error())
        end
        completions[co]=finish
    else completions[co]=done end
    if scope then scopes[co]=scope;scope.members[co]=true end
    M.resume(co)
end
function M.check(value,e)
    if not value then error(e or Errors.new('IO','操作没有返回有效结果'),0) end
    return value
end
function M.call(start)
    local e,value=M.await(start)
    if e then error(e,0) end
    return value
end
return M
