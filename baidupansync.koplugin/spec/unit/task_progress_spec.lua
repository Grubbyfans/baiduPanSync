describe('unified book task progress',function()
    local UI,Progress,baseline,tracker
    setup(function()require('commonrequire');UI=require('ui/uimanager');Progress=require('ui/task_progress')end)
    before_each(function()baseline={};for _,window in ipairs(UI._window_stack)do baseline[window.widget]=true end end)
    after_each(function()
        if tracker then tracker:close()end
        for i=#UI._window_stack,1,-1 do local w=UI._window_stack[i].widget;if not baseline[w]then UI:close(w)end end
    end)
    local function shown(widget)
        local count=0;for _,window in ipairs(UI._window_stack)do if window.widget==widget then count=count+1 end end;return count
    end
    it('keeps one dialog and does not finish the task at transfer 100 percent',function()
        tracker=Progress.new('upload_book','百度网盘 · 我的账户')
        tracker:state('preparing');local widget=tracker.dialog
        tracker:hash_start(1024);tracker:report(1024,1024)
        tracker:state('reading_remote');tracker:state('writing');tracker:report(1048576,1048576)
        assert.is_equal(3,tracker.stage);assert.is_nil(tracker.completed);assert.is_equal(1,shown(widget))
        tracker:state('verifying');tracker:phase('核对整书 SHA-256');tracker:hash_start(1048576);tracker:report(1048576,1048576)
        assert.is_equal(4,tracker.stage);assert.is_nil(tracker.completed)
        tracker:phase('发布书库记录');assert.is_equal(5,tracker.stage);assert.is_nil(tracker.completed)
        tracker:state('done');assert.is_true(tracker.completed);assert.is_equal(widget,tracker.dialog)
    end)
    it('pauses for confirmation without cancelling and resumes the same dialog',function()
        tracker=Progress.new('download_book','WebDAV · test/sync/')
        tracker:state('reading_remote');local widget=tracker.dialog
        tracker:state('awaiting_confirm');assert.is_equal(0,shown(widget));assert.is_false(tracker:is_cancelled())
        tracker:state('rechecking');assert.is_equal(1,shown(widget));assert.is_false(tracker:is_cancelled())
        tracker:close();tracker:close();assert.is_equal(0,shown(widget))
        tracker:report(20,20);tracker:state('downloading');assert.is_equal(0,shown(widget))
    end)
    it('passes explicit user cancellation to the active transport',function()
        local cancelled=0
        tracker=Progress.new('repair_book','WebDAV · test/sync/')
        tracker:state('verifying');tracker:attach(function()cancelled=cancelled+1 end,{download_path='file.part'})
        tracker.dialog.dismiss_callback()
        assert.is_true(tracker:is_cancelled());assert.is_equal(1,cancelled)
        tracker:report(1,1);tracker:state('committing_local');assert.is_equal(2,tracker.stage)
    end)
    it('retains the shared view across small requests and separates the repair hash stage',function()
        tracker=Progress.new('repair_book','WebDAV · test/sync/')
        tracker:state('verifying');local widget=tracker.dialog
        local cancel=function()end
        tracker:attach(cancel,{});tracker:detach(cancel);tracker:attach(cancel,{})
        assert.is_equal(1,shown(widget));assert.is_equal(widget,tracker.dialog)
        tracker:phase('核对整书 SHA-256');tracker:hash_start(100);assert.is_equal(3,tracker.stage)
        tracker:phase('发布修复后的书库记录');assert.is_equal(4,tracker.stage)
    end)
    it('renders the native stage list and current-stage byte progress',function()
        tracker=Progress.new('upload_book','百度网盘 · 我的账户')
        tracker:state('writing');tracker:report(3*1048576,10*1048576)
        local screen=require('device').screen;screen.bb:fill(require('ffi/blitbuffer').COLOR_WHITE)
        tracker.dialog:paintTo(screen.bb,0,0)
        local path=os.getenv('BPS_TASK_PREVIEW');if path then assert(screen:shot(path))end
        assert.is_truthy(tracker:counter_text():find('3.00 / 10.00',1,true))
    end)
end)
