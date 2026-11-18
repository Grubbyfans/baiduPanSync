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
end)
