-- Unique C2 test resources only; no book/metadata/progress paths are touched.
local A=require('modules/async')
local E=require('modules/errors')
local Random=require('modules/random')
local json=require('json')
local M={}
function M.run(api,done)
    local dir
    A.run(function()
        local info=A.call(function(cb)api:user_info(cb)end)
        if info.user_id~=api.profile.user_id then error(E.new('AUTH','百度账户与已保存凭据身份不一致，请重新授权'),0) end
        dir='c2-probe-'..A.check(Random.hex(16))
        local path=dir..'/probe.json'
        local payload=json.encode{kind='BaiduPanSync C2 probe',nonce=A.check(Random.hex(16))}
        A.call(function(cb)api:mkdir(dir,cb)end)
        A.call(function(cb)api:uploadSmallJson(path,payload,nil,cb)end)
        local list=A.call(function(cb)api:list(dir,nil,cb)end)
        local found=false
        for _,entry in ipairs(list.entries) do if entry.path==path then found=true end end
        if not found then error(E.new('CONFLICT','百度测试文件枚举未找到刚上传的文件'),0) end
        local raw=A.call(function(cb)api:download(path,cb)end)
        if raw~=payload then error(E.new('CONFLICT','百度测试文件回读内容不一致'),0) end
        A.call(function(cb)api:delete(path,nil,cb)end)
        local err=A.await(function(cb)api:stat(path,cb)end)
        if not err or err.code~='NOT_FOUND' then error(err or E.new('UNCERTAIN','百度测试文件删除后仍可查询'),0) end
        return {directory=api.root..'/'..dir,account=info.name,user_id=info.user_id,
            backend_id=api.backend_id,conditional_write=false,conditional_delete=false,verified_at=os.time()}
    end,function(e,result)
        -- After a failed/cancelled write do not guess what exists, and do not
        -- automatically repeat commits or issue broad cleanup requests.
        done(e,result or {directory=dir and api.root..'/'..dir or nil})
    end)
end
return M
