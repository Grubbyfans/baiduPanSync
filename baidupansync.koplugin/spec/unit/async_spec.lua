describe('asynchronous task watchdog',function()
    local A,timers,opts,events
    setup(function()require('commonrequire');A=require('modules/async')end)
    before_each(function()
        timers={};events={}
        opts={timeout=10,schedule=function(_,cb)timers[cb]=true end,
            unschedule=function(cb)timers[cb]=nil end,
            error=function()return {code='NETWORK',message='timeout'}end}
    end)
    local function expire()
        local cb=next(timers);assert.is_truthy(cb);timers[cb]=nil;cb()
    end
    it('cancels nested resources before completion and ignores late callbacks',function()
        local pending,count
        count=0
        A.run(function()
            return A.call(function(done)
                A.run(function()
                    return A.call(function(cb)
                        pending=cb
                        A.on_cancel(function()events[#events+1]='cancel';cb(nil,'late')end)
                    end)
                end,done)
            end)
        end,function(e)
            count=count+1;assert.is_equal('NETWORK',e.code);events[#events+1]='finish'
        end,opts)
        expire()
        assert.are.same({'cancel','finish'},events)
        pending(nil,'later');assert.is_equal(1,count)
        assert.is_nil(next(timers))
    end)
    it('does not time out user confirmation and rearms after the choice',function()
        local choose,reply,finished
        A.run(function()
            A.await(function(cb)choose=cb end,{no_timeout=true})
            return A.call(function(cb)reply=cb end)
        end,function(e)finished=e end,opts)
        assert.is_nil(next(timers))
        choose(true);assert.is_truthy(next(timers))
        expire();assert.is_equal('NETWORK',finished.code)
        reply(nil,{});assert.is_nil(next(timers))
    end)
    it('disarms on success and permits subsequent independent tasks',function()
        local pending,count
        count=0
        A.run(function()return A.call(function(cb)pending=cb end)end,function(e,v)
            assert.is_nil(e);assert.is_equal('ok',v);count=count+1
        end,opts)
        local stale=next(timers)
        pending(nil,'ok');assert.is_nil(next(timers));stale()
        A.run(function()return 'ok'end,function(e,v)
            assert.is_nil(e);assert.is_equal('ok',v);count=count+1
        end,opts)
        assert.is_equal(2,count);assert.is_nil(next(timers))
    end)
end)
