describe('parent transport watchdog',function()
    local A,Transport,original,timers,worker,terminated,closed
    setup(function()require('commonrequire');A=require('modules/async');Transport=require('modules/dav_transport')end)
    before_each(function()
        original={}
        for _,name in ipairs({'ui/uimanager','ui/trapper','ui/widget/trapwidget'}) do original[name]=package.loaded[name] or false end
        timers={};terminated=false;closed=false
        package.loaded['ui/uimanager']={
            scheduleIn=function(_,seconds,cb)timers[cb]=seconds end,
            unschedule=function(_,cb)timers[cb]=nil end,
            show=function()end,forceRePaint=function()end,close=function()closed=true end,
        }
        package.loaded['ui/widget/trapwidget']={new=function(_,o)return o end}
        package.loaded['ui/trapper']={wrap=function(_,fn)
            worker=coroutine.create(fn);assert(coroutine.resume(worker))
        end,dismissableRunInSubprocess=function(_,_,widget)
            widget.dismiss_callback=function()
                terminated=true;assert(coroutine.resume(worker,false))
            end
            return coroutine.yield()
        end}
    end)
    after_each(function()for name,value in pairs(original) do package.loaded[name]=value~=false and value or nil end end)
    for _,method in ipairs({'GET','PUT'}) do
        it('terminates a stalled '..method..' and reports its outcome once',function()
            local count,err=0
            A.run(function()
                return A.call(function(cb)Transport.request({url='http://fixture/',method=method},cb)end)
            end,function(e)
                count=count+1;err=e;assert.is_true(terminated);assert.is_true(closed)
            end,{
                timeout=3700,schedule=function(s,cb)timers[cb]=s end,
                unschedule=function(cb)timers[cb]=nil end,
                error=function()return {code='NETWORK',message='outer timeout'}end,
            })
            assert.is_equal(0,count)
            local deadline
            for cb,seconds in pairs(timers) do if seconds==155 then deadline=cb end end
            assert.is_truthy(deadline);deadline()
            assert.is_equal(method=='PUT' and 'UNCERTAIN' or 'NETWORK',err.code)
            assert.is_equal(1,count);assert.is_nil(next(timers))
            deadline();assert.is_equal(1,count)
        end)
    end
    it('uses shared task progress, accumulates slice bytes and keeps ownership with the task',function()
        local lfs=require('libs/libkoreader-lfs')
        local root=os.tmpname();os.remove(root);assert(lfs.mkdir(root))
        local attached,detached,reported,err,calls
        calls=0
        local shared={attach=function(_,cancel)attached=cancel end,
            detach=function(_,cancel)assert.is_equal(attached,cancel);detached=true end,
            report=function(_,count,total)reported={count,total}end}
        local req={url='http://fixture/',method='PUT',upload_path='/unused.epub',upload_size=1024,
            task_transfer_offset=1024,task_transfer_total=4096,progress_dir=root,task_progress=shared}
        local ok,failure=pcall(function()
            Transport.request(req,function(e)err=e;calls=calls+1 end)
            assert.is_truthy(attached);assert.is_false(closed)
            local status=assert(io.open(req.progress_path,'wb'));status:write('512');status:close()
            local poll
            for cb,seconds in pairs(timers) do if seconds==0.2 then poll=cb end end
            assert.is_truthy(poll);poll();assert.are.same({1536,4096},reported)
            attached();assert.is_true(terminated);assert.is_true(detached)
            assert.is_equal('UNCERTAIN',err.code);assert.is_equal(1,calls)
            assert.is_false(closed);assert.is_nil(lfs.attributes(req.progress_path));assert.is_nil(next(timers))
            poll();assert.is_equal(1,calls);assert.is_nil(next(timers))
        end)
        if req.progress_path then os.remove(req.progress_path)end;lfs.rmdir(root)
        assert.is_true(ok,tostring(failure))
    end)
end)
