-- Disposable, unpredictable resources qualify conditional create/replace/delete.
local A=require('modules/async')
local Errors=require('modules/errors')
local M={}
function M.run(adapter,done)
    local token,e=require('modules/random').hex(16);if not token then return done(e) end
    local dir='.baidupansync-probe-'..token
    local path=dir..'/probe.json'
    local text='{"probe":"'..token..'"}'
    local report={directory=dir,conditional_create=false,conditional_replace=false,conditional_delete=false}
    local function call(method,...)
        local args,n={...},select('#',...)
        return A.call(function(cb)args[n+1]=cb;adapter[method](adapter,unpack(args,1,n+1))end)
    end
    local function require_true(ok,message)
        if not ok then error(Errors.new('UNSUPPORTED',message),0) end
    end
    A.run(function()
        call('mkdir',dir)
        adapter.conditional_verified=true -- only within our random probe namespace
        call('uploadSmallJson',path,text,{absent=true})
        local ce=A.await(function(cb)adapter:uploadSmallJson(path,'{}',{absent=true},cb)end)
        require_true(ce and ce.code=='CONFLICT','服务没有拒绝重复条件创建')
        require_true(call('download',path)==text,'条件创建未保护已有数据')
        report.conditional_create=true
        local list=call('list',dir..'/',nil)
        require_true(#list.entries==1 and list.entries[1].path==path,'枚举与探测文件不符')
        local st=call('stat',path)
        require_true(st.etag and not st.weak_etag,'没有可验证的强 ETag')
        local wrong='"bps-invalid-'..token..'"'
        ce=A.await(function(cb)adapter:uploadSmallJson(path,'{}',{etag=wrong},cb)end)
        require_true(ce and ce.code=='CONFLICT','服务没有拒绝错误 If-Match')
        require_true(call('download',path)==text,'错误 If-Match 破坏了文件')
        call('uploadSmallJson',path,'{}',{etag=st.etag})
        require_true(call('download',path)=='{}','条件替换回读不符')
        report.conditional_replace=true
        -- Deletion qualification is separate; unsupported DELETE never licenses
        -- withdrawing a published sidecar during same-name replacement.
        local de=A.await(function(cb)adapter:delete(path,{etag=wrong},cb)end)
        local se,after=A.await(function(cb)adapter:stat(path,cb)end)
        if de and de.code=='CONFLICT' and not se and call('download',path)=='{}' then
            call('delete',path,{etag=after.etag})
            local missing=A.await(function(cb)adapter:stat(path,cb)end)
            report.conditional_delete=missing and missing.code=='NOT_FOUND' or false
        end
        return report
    end,function(probe_err)
        adapter.conditional_verified=report.conditional_create and report.conditional_replace
        adapter.conditional_delete_verified=report.conditional_delete
        A.run(function()
            local stat_err=A.await(function(cb)adapter:stat(path,cb)end)
            if stat_err and stat_err.code=='NOT_FOUND' then return end
            if stat_err then report.cleanup_error=stat_err;return end
            local clean=A.await(function(cb)adapter:delete(path,nil,cb)end)
            report.cleanup_error=clean
        end,function(clean_err)
            report.cleanup_error=report.cleanup_error or clean_err
            done(probe_err,report)
        end)
    end)
end
return M
