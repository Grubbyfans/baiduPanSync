-- Bounded local summaries only. Never retain URLs, credentials or book content.
local M={};M.__index=M
local function clock()
    local ok,socket=pcall(require,'socket')
    return ok and socket.gettime and socket.gettime() or os.time()
end
function M.new(o)
    o=o or {};local now=o.clock or clock
    return setmetatable({now=now,started=now(),data={version=o.version or '',operation=o.operation or 'unknown',backend=o.backend or 'local',
        started_at=os.time(),request_count=0,request_errors=0,request_seconds=0,cache_hits={},cache_misses={},stages={}}},M)
end
function M:stage(name)
    if self.finished or self.current and self.current.name==name then return end
    local now=self.now()
    if self.current then self.current.seconds=math.max(0,now-self.stage_started)end
    self.current={name=name,seconds=0,requests=0};self.stage_started=now
    self.data.stages[#self.data.stages+1]=self.current
end
function M:cache(kind,hit)
    if self.finished then return end
    local counts=hit and self.data.cache_hits or self.data.cache_misses
    counts[kind]=(counts[kind] or 0)+1
end
function M:request()
    if self.finished then return function()end end
    self.data.request_count=self.data.request_count+1
    if self.current then self.current.requests=self.current.requests+1 end
    local started=self.now();local called=false
    return function(e,result)
        if called or self.finished then return end;called=true
        self.data.request_seconds=self.data.request_seconds+math.max(0,self.now()-started)
        if e or result and result.status and result.status>=400 then self.data.request_errors=self.data.request_errors+1 end
    end
end
function M:finish(result)
    if self.finished then return self.data end
    local now=self.now();if self.current then self.current.seconds=math.max(0,now-self.stage_started)end
    self.data.seconds=math.max(0,now-self.started);self.data.result=result or 'success';self.finished=true
    return self.data
end
function M.observe(tracker,transport,request,done)
    local finish=tracker and tracker:request()
    return transport(request,function(e,v)if finish then finish(e,v)end;done(e,v)end)
end
local function number(v)return type(v)=='number' and v==v and v>=0 and v<math.huge end
local function valid(v)
    if type(v)~='table' or type(v.version)~='string' or type(v.operation)~='string' or type(v.backend)~='string'
        or type(v.result)~='string' or not number(v.started_at) or not number(v.seconds) or not number(v.request_seconds)
        or not number(v.request_count) or not number(v.request_errors) or type(v.stages)~='table' or #v.stages>128
        or type(v.cache_hits)~='table' or type(v.cache_misses)~='table' then return false end
    for _,stage in ipairs(v.stages)do
        if type(stage)~='table' or type(stage.name)~='string' or #stage.name>256 or not number(stage.seconds) or not number(stage.requests)then return false end
    end
    for _,counts in ipairs({v.cache_hits,v.cache_misses})do
        for kind,count in pairs(counts)do if type(kind)~='string' or #kind>64 or not number(count)then return false end end
    end
    return true
end
function M.read(dir)
    local raw,e=require('modules/file_util').read_file(dir..'/diagnostics.json',128*1024)
    if not raw then if e.code=='NOT_FOUND'then return {}end;return nil,e end
    local ok,v=pcall(require('json').decode,raw)
    if not ok or type(v)~='table' or v.schemaVersion~=1 or type(v.tasks)~='table' or #v.tasks>20 then
        return nil,require('modules/errors').new('INVALID_INPUT','诊断记录损坏或版本不支持，原文件保留')
    end
    for _,task in ipairs(v.tasks)do if not valid(task)then return nil,require('modules/errors').new('INVALID_INPUT','诊断任务记录无效，原文件保留')end end
    return v.tasks
end
function M.save(dir,record)
    if not valid(record)then return nil,require('modules/errors').new('INVALID_INPUT','诊断数据无效')end
    local tasks,e=M.read(dir);if not tasks then return nil,e end
    tasks[#tasks+1]=record;while #tasks>20 do table.remove(tasks,1)end
    local Files=require('modules/file_util')
    local ok,raw=pcall(require('json').encode,{schemaVersion=1,tasks=tasks})
    if not ok or #raw>128*1024 then return nil,require('modules/errors').new('INVALID_INPUT','诊断记录超过大小限制')end
    local made,me=Files.mkdir_p(dir);if not made then return nil,me end
    return Files.write_atomic(dir..'/diagnostics.json',raw)
end
function M.format(tasks)
    local lines={'最近任务诊断（仅本机保存，最多 20 项）','请求数包含失败尝试；阶段耗时包含等待确认，封面加载单独记录。'}
    for i=#tasks,1,-1 do
        local v=tasks[i]
        lines[#lines+1]=string.format('\n%s · %s · %s · %s',os.date('%Y-%m-%d %H:%M:%S',v.started_at),v.version,v.backend,v.operation)
        lines[#lines+1]=string.format('结果：%s；总耗时 %.2f 秒；HTTP %d 次（失败响应 %d 次），请求累计 %.2f 秒',
            v.result,v.seconds,v.request_count,v.request_errors,v.request_seconds)
        for _,kind in ipairs({'library','cover','download_link'})do
            lines[#lines+1]=string.format('缓存 %s：命中 %d，未命中 %d',kind,(v.cache_hits or {})[kind] or 0,(v.cache_misses or {})[kind] or 0)
        end
        for _,stage in ipairs(v.stages or {})do lines[#lines+1]=string.format('  %s：%.2f 秒，%d 次请求',stage.name,stage.seconds,stage.requests)end
    end
    return table.concat(lines,'\n')
end
return M
