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
        source=function()
            if require('socket').gettime()-started>120 then return nil,'upload timeout' end
            local chunk,e=input:read(65536)
            if chunk then digest(chunk);uploaded=uploaded+#chunk;report(uploaded) end
            return chunk,e
        end
    elseif req.body then source=ltn12.source.string(req.body) end
    if req.download_path then
        -- Parent owns/reserves this file: r+b never recreates a cancelled temp.
        output=io.open(req.download_path,'r+b')
        if not output then if input then input:close() end;return Errors.new('IO','无法打开下载临时文件') end
    end
    headers['Content-Length']=tostring(req.upload_size or (req.body and #req.body) or 0)
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
    trapper:wrap(function()
        local dialog,marker,poll
        local UI=require('ui/uimanager')
        if (req.upload_path or req.download_path) and req.progress_dir then
            local ok=require('modules/file_util').mkdir_p(req.progress_dir)
            local token,e=require('modules/random').hex(16)
            if not ok or not token then return done(e or Errors.new('IO','无法建立传输进度目录')) end
            marker=req.progress_dir..'/transfer-'..token..'.status'
            local status_file=io.open(marker,'wb')
            if not status_file then return done(Errors.new('IO','无法创建传输进度文件')) end
            status_file:write('0');status_file:close()
            req.progress_path=marker
            local total=req.upload_size or req.max_bytes
            dialog=require('ui/widget/progressbardialog'):new{
                title=req.upload_path and '正在上传 EPUB' or '正在下载 EPUB',
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
        local completed,e,r=trapper:dismissableRunInSubprocess(function() return M.perform(req) end,
            dialog or '正在访问 WebDAV（点击可取消）…')
        if dialog then dialog:close();dialog=nil;UI:unschedule(poll) end
        if marker then os.remove(marker) end
        if not completed then
            handle.cancelled=true
            local write=writing(req)
            e=Errors.new(write and 'UNCERTAIN' or 'CANCELLED',
                write and '已取消等待，远端写入结果未知，请重新查询' or '已取消请求',
                {outcome=write and 'uncertain' or 'failed'})
        end
        done(e,r)
    end)
    return handle
end
return M
