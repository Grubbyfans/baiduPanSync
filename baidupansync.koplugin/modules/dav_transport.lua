-- HTTP is isolated in a cancellable child process, never a UI-thread socket call.
-- HTTPS uses independent chain + SAN verification; missing trust fails closed.
local Errors = require('modules/errors')
local M = {}
local function writing(req)
    return req.writing or req.method=='PUT' or req.method=='MKCOL' or req.method=='DELETE'
end
function M.perform(req)
    local secure=req.url:match('^https:')~=nil
    local create,tls_state
    if secure then
        local reason
        create,reason,tls_state=require('modules/dav_tls').factory(req.cafile)
        if not create then return Errors.new('TLS',reason) end
        local url=require('socket.url')
        local parsed=url.parse(req.url);parsed.port=parsed.port or 443
        req.url=url.build(parsed)
    end
    local http=require('socket.http')
    local ltn12=require('ltn12')
    local mime=require('mime')
    local socketutil=require('socketutil')
    local parts,bytes={},0
    local started=require('socket').gettime()
    local last_report=0
    local function report(count,force)
        if not req.progress_path then return end
        local now=require('socket').gettime()
        if not force and now-last_report<0.2 then return end
        last_report=now
        local f=io.open(req.progress_path,'r+b')
        if f then f:write(tostring(count));f:close() end
    end
    local headers={Connection='close'}
    if req.username then headers.Authorization='Basic '..mime.b64(req.username..':'..req.password) end
    for k,v in pairs(req.headers or {}) do headers[k]=v end
    local input,output,source
    local digest=req.upload_path and require('ffi/sha2').sha256()
    local uploaded=0
    if req.upload_path then
        input=io.open(req.upload_path,'rb')
        if not input then return Errors.new('IO','无法打开上传文件') end
        if req.upload_offset and not input:seek('set',req.upload_offset) then
            input:close();return Errors.new('IO','无法定位上传分片')
        end
        local prefix,suffix=req.upload_prefix,req.upload_suffix
        local prefix_sent,suffix_sent=false,false
        source=function()
            if require('socket').gettime()-started>120 then return nil,'upload timeout' end
            if prefix and not prefix_sent then prefix_sent=true;return prefix end
            if req.upload_size and uploaded==req.upload_size then
                if suffix and not suffix_sent then suffix_sent=true;return suffix end
                return nil
            end
            local chunk,e=input:read(req.upload_size and math.min(65536,req.upload_size-uploaded) or 65536)
            if chunk then digest(chunk);uploaded=uploaded+#chunk;report(uploaded) end
            if not chunk and req.upload_size and uploaded~=req.upload_size then return nil,'source truncated' end
            return chunk,e
        end
    elseif req.body then source=ltn12.source.string(req.body) end
    if req.download_path then
        -- Parent owns/reserves this file: r+b never recreates a cancelled temp.
        output=io.open(req.download_path,'r+b')
        if not output then if input then input:close() end;return Errors.new('IO','无法打开下载临时文件') end
        if req.reset_download then
            -- New task-owned files are already empty; older KOReader builds may
            -- not declare ftruncate. Only a redirect retry needs truncation.
            local length=output:seek('end')
            local ok,truncated=true,true
            if length and length>0 then
                ok,truncated=pcall(function()
                    require('ffi/posix_h')
                    local ffi=require('ffi')
                    -- Older KOReader headers define the platform's off_t and
                    -- fileno but omit ftruncate (confirmed on v2026.03).
                    -- Reuse that ABI type; never guess long/int64 on 32-bit.
                    if not pcall(function()return ffi.C.ftruncate end) then
                        ffi.cdef[[int ftruncate(int fd, off_t length);]]
                    end
                    return ffi.C.ftruncate(ffi.C.fileno(output),0)==0
                end)
            end
            if not length or not ok or not truncated or not output:seek('set',0) then
                output:close();if input then input:close() end
                return Errors.new('IO','无法重置下载临时文件；请检查 KOReader 系统接口与目录写权限')
            end
        end
    end
    headers['Content-Length']=tostring(req.upload_path and
        ((req.upload_size or 0)+#(req.upload_prefix or '')+#(req.upload_suffix or '')) or (req.body and #req.body) or 0)
    socketutil:set_timeout(10,120)
    local ok,success,status,response_headers=pcall(http.request,{
        url=req.url,method=req.method,headers=headers,redirect=false,create=create,
        source=source,
        sink=function(chunk)
            if require('socket').gettime()-started>120 then return nil,'total timeout' end
            if chunk then
                bytes=bytes+#chunk
                if bytes>(req.max_bytes or 1024*1024) then return nil,'response too large' end
                if output then
                    local wrote=output:write(chunk)
                    if not wrote then return nil,'disk write failed' end
                    report(bytes)
                else parts[#parts+1]=chunk end
            end
            return 1
        end,
    })
    socketutil:reset_timeout()
    if input then input:close() end
    local output_ok=true
    if output then
        pcall(require('ffi/util').fsyncOpenedFile,output)
        output_ok=output:close()
    end
    local upload_hash=digest and digest()
    report(req.upload_path and uploaded or bytes,true)
    if not ok or not success or not output_ok then
        local write=writing(req)
        return Errors.new(write and 'UNCERTAIN' or (tls_state and tls_state.code or 'NETWORK'),'连接或传输未完成（HTTPS 请检查证书、SAN 与 CA）；请重新查询结果',
            {retryable=not write,outcome=write and 'uncertain' or 'failed'})
    end
    if req.expected_sha256 and req.upload_path and (upload_hash~=req.expected_sha256 or uploaded~=req.upload_size) then
        return Errors.new('UNCERTAIN','上传流与预期摘要不同，未发布；请重新核对源文件',{outcome='uncertain'})
    end
    return nil,{status=tonumber(status),headers=response_headers or {},body=table.concat(parts),
        size=bytes,upload_sha256=upload_hash,uploaded=uploaded}
end
function M.request(req,done)
    local trapper=require('ui/trapper')
    local handle={cancelled=false}
    local called=false
    local function finish(e,r)
        if called then return end;called=true;done(e,r)
    end
    trapper:wrap(function()
        local dialog,marker,poll
        local UI=require('ui/uimanager')
        local ok,err=pcall(function()
            if (req.upload_path or req.download_path) and req.progress_dir then
                local ok=require('modules/file_util').mkdir_p(req.progress_dir)
                local token,e=require('modules/random').hex(16)
                if not ok or not token then return finish(e or Errors.new('IO','无法建立传输进度目录')) end
                marker=req.progress_dir..'/transfer-'..token..'.status'
                local status_file=io.open(marker,'wb')
                if not status_file then return finish(Errors.new('IO','无法创建传输进度文件')) end
                status_file:write('0');status_file:close()
                req.progress_path=marker
                local total=req.upload_size or req.max_bytes
                dialog=require('ui/widget/progressbardialog'):new{
                    title=req.progress_title or (req.upload_path and '正在上传 EPUB' or '正在下载 EPUB'),
                    subtitle='点击可取消；写入取消后请重新查询云端状态',progress_max=total>0 and total or nil,
                    refresh_time_seconds=0.5,
                }
                dialog:show()
                poll=function()
                    if not dialog then return end
                    local f=io.open(marker,'rb')
                    if f then local count=tonumber(f:read(32));f:close();if count and total>0 then dialog:reportProgress(math.min(count,total)) end end
                    UI:scheduleIn(0.2,poll)
                end
                UI:scheduleIn(0.2,poll)
            end
            local completed,e,r=trapper:dismissableRunInSubprocess(function()
                local ok,a,b=pcall(M.perform,req)
                if not ok then return Errors.exception(a,'网络传输子进程',writing(req)) end
                return a,b
            end,
                dialog or req.wait_message or '正在访问 WebDAV（点击可取消）…')
            if not completed then
                handle.cancelled=true
                local write=writing(req)
                e=Errors.new(write and 'UNCERTAIN' or 'CANCELLED',
                    write and '已取消等待，远端写入结果未知，请重新查询' or '已取消请求',
                    {outcome=write and 'uncertain' or 'failed'})
            elseif not e and (type(r)~='table' or type(r.status)~='number') then
                local write=writing(req)
                e=Errors.new(write and 'UNCERTAIN' or 'NETWORK','网络传输子进程没有返回有效结果；可能异常退出，请检查 KOReader 日志',
                    {outcome=write and 'uncertain' or 'failed'})
            end
            -- Clean up before handing control back to a callback that may start
            -- another request. Closing normally must never trigger cancellation.
            if dialog then dialog.dismiss_callback=nil;dialog:close();dialog=nil;UI:unschedule(poll) end
            if marker then os.remove(marker);marker=nil end
            finish(e,r)
        end)
        if dialog then dialog.dismiss_callback=nil;pcall(dialog.close,dialog);if poll then UI:unschedule(poll) end end
        if marker then os.remove(marker) end
        if not ok then finish(Errors.exception(err,'网络传输',writing(req))) end
    end)
    return handle
end
return M
