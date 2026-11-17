-- Callback/coroutine bridge, including callbacks which finish synchronously.
local Errors=require('modules/errors')
local M={}
function M.await(start)
    local co=coroutine.running()
    local pending,called=true,false
    local result
    start(function(...)
        if called then return end
        called=true;result={...};result.n=select('#',...)
        if not pending then M.resume(co,unpack(result,1,result.n)) end
    end)
    pending=false
    if called then return unpack(result,1,result.n) end
    return coroutine.yield()
end
local completions=setmetatable({},{__mode='k'})
function M.resume(co,...)
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
function M.run(fn,done)
    local co=coroutine.create(fn);completions[co]=done;M.resume(co)
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
