-- Fixed 4 MiB slices, 64 KiB reads; yields between reads and owns its file.
local sha=require('ffi/sha2')
local lfs=require('libs/libkoreader-lfs')
local E=require('modules/errors')
local M={BLOCK_SIZE=4*1024*1024,MAX_SIZE=1024*1024*1024}
function M.file(path,opts,done)
    opts=opts or {}
    local st=lfs.attributes(path)
    if not st or st.mode~='file' or st.size<1 or st.size>M.MAX_SIZE then
        return done(E.new('INVALID_INPUT','百度上传要求可读的非空文件，最大 1 GiB'))
    end
    local f=io.open(path,'rb');if not f then return done(E.new('IO','无法读取上传源文件')) end
    local plan={size=st.size,mtime=st.modification,blocks={},parts={}}
    local total,part_size=0,0
    local full,md5,part_sha=sha.sha256(),sha.md5(),sha.sha256()
    local finished=false
    local function finish(err)
        if finished then return end;finished=true;f:close()
        if opts.on_hash_finish then opts.on_hash_finish() end
        done(err,not err and plan or nil)
    end
    local function changed()
        local current=lfs.attributes(path)
        return not current or current.size~=st.size or current.modification~=st.modification
    end
    local function step()
        if opts.is_cancelled and opts.is_cancelled() then return finish(E.new('CANCELLED','已取消百度上传分片检查')) end
        if changed() then return finish(E.new('CONFLICT','上传源文件在分片检查期间发生变化')) end
        local chunk=f:read(math.min(65536,st.size-total,M.BLOCK_SIZE-part_size))
        if not chunk or #chunk==0 then return finish(E.new('IO','上传源文件读取不完整')) end
        full(chunk);md5(chunk);part_sha(chunk);total=total+#chunk;part_size=part_size+#chunk
        if part_size==M.BLOCK_SIZE or total==st.size then
            plan.blocks[#plan.blocks+1]=md5()
            plan.parts[#plan.parts+1]={offset=total-part_size,size=part_size,sha256=part_sha()}
            md5=sha.md5();part_sha=sha.sha256();part_size=0
        end
        if opts.on_progress then opts.on_progress(total,st.size) end
        if total==st.size then
            if changed() then return finish(E.new('CONFLICT','上传源文件在分片检查后发生变化')) end
            plan.sha256=full();return finish()
        end
        (opts.schedule or function(cb)require('ui/uimanager'):scheduleIn(0,cb)end)(step)
    end
    if opts.on_hash_start then opts.on_hash_start(st.size) end
    step()
end
return M
