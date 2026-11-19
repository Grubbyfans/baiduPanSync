-- Small, bounded official API requests over the same verified TLS transport.
local Errors=require('modules/errors')
local json=require('json')
local M={}
function M.escape(value)
    return (tostring(value):gsub('[^%w%-._~]',function(c)return string.format('%%%02X',c:byte())end))
end
function M.form(values)
    local parts={}
    for key,value in pairs(values) do parts[#parts+1]=M.escape(key)..'='..M.escape(value) end
    table.sort(parts);return table.concat(parts,'&')
end
function M.decode(raw)
    if type(raw)~='string' or #raw>1048576 then return nil end
    -- Preserve decimal IDs exactly, including IDs beyond Lua's 2^53 limit.
    raw=raw:gsub('("uk"%s*:%s*)(%d+)', '%1"%2"')
        :gsub('("fs_id"%s*:%s*)(%d+)', '%1"%2"')
    local ok,v=pcall(json.decode,raw)
    return ok and type(v)=='table' and v or nil
end
function M.request(opts,done)
    local transport=opts.transport or require('modules/dav_transport').request
    local req={url=opts.url,method=opts.method or 'GET',body=opts.body,cafile=opts.cafile,
        headers=opts.headers or {['User-Agent']='pan.baidu.com'},max_bytes=opts.max_bytes or 1048576,
        writing=opts.writing,task_progress=opts.task_progress,
        task_transfer_offset=opts.task_transfer_offset,task_transfer_total=opts.task_transfer_total}
    for _,key in ipairs({'upload_path','upload_offset','upload_size','upload_prefix','upload_suffix',
        'expected_sha256','download_path','progress_dir'}) do req[key]=opts[key] end
    req.wait_message='正在访问百度网盘（点击可取消）…'
    return transport(req,function(e,r)
        if e then return done(e) end
        if not r or r.status~=200 then
            return done(Errors.new(opts.writing and 'UNCERTAIN' or 'NETWORK',
                '百度 HTTP 请求失败：'..tostring(r and r.status or '无响应'),
                {outcome=opts.writing and 'uncertain' or 'failed'}))
        end
        if opts.raw then return done(nil,r.body) end
        local v=M.decode(r.body)
        if not v then return done(Errors.new('INVALID_INPUT','百度返回的数据无效')) end
        if v.error or (v.errno~=nil and v.errno~=0) or (v.error_code~=nil and v.error_code~=0) then
            local n=v.errno or v.error_code or v.error
            local auth=n==110 or n==111 or n==-6 or n==20016 or n==20017 or n==31045
                or n=='invalid_grant' or n=='invalid_client'
            local public_code=type(n)=='number' and tostring(n) or
                ({invalid_grant=true,invalid_client=true,invalid_request=true,invalid_scope=true,
                    unsupported_grant_type=true,access_denied=true})[n] and n or 'unknown'
            return done(Errors.new(auth and 'AUTH' or n==-9 and 'NOT_FOUND' or n==-8 and 'CONFLICT' or 'FORBIDDEN',
                auth and '百度授权无效或已过期，请重新授权' or '百度接口拒绝请求（错误码 '..public_code..'）'))
        end
        done(nil,v)
    end)
end
return M
