describe('reading progress comparison',function()
    local UI,CloudUI,Plugin,Cloud,original,baseline,context,result
    setup(function()
        require('commonrequire')
        UI=require('ui/uimanager');CloudUI=require('ui/cloud_dialog');Cloud=require('modules/cloud_service')
        Plugin=dofile(os.getenv('BPS_PLUGIN_ROOT')..'/main.lua')
    end)
    before_each(function()
        original=Cloud.new;baseline={}
        for _,window in ipairs(UI._window_stack)do baseline[window.widget]=true end
        context={book={file_path='/books/test.epub',file_name='test.epub',title='测试书籍'},
            progress={type='xpointer',value='/local',percent=0.35}}
        result={backend='http://192.168.1.2/sync/',remote={record={progress={percent=0.42},
            sync={deviceId='Kobo',updatedAt='2026-11-18T10:00:00Z'}}}}
    end)
    after_each(function()
        Cloud.new=original
        for i=#UI._window_stack,1,-1 do
            local widget=UI._window_stack[i].widget
            if not baseline[widget]then UI:close(widget)end
        end
    end)
    it('shows both positions without automatically choosing a direction',function()
        local calls=0
        local dialog=CloudUI.query(result,context,{upload=function()calls=calls+1 end,download=function()calls=calls+10 end})
        assert.is_truthy(dialog.title:find('35.0%%'));assert.is_truthy(dialog.title:find('42.0%%'))
        assert.is_truthy(dialog.title:find('Kobo',1,true));assert.is_equal(0,calls)
        assert.is_true(dialog.buttons[2][1].enabled)
        dialog.buttons[1][1].callback();assert.is_equal(1,calls)
    end)
    it('permits first upload but disables apply when there is no remote progress',function()
        result.remote=nil;context.progress.percent=nil
        local dialog=CloudUI.query(result,context,{upload=function()end,download=function()end})
        assert.is_true(dialog.buttons[1][1].enabled);assert.is_false(dialog.buttons[2][1].enabled)
        assert.is_false(dialog.buttons[3][2].enabled)
        assert.is_truthy(dialog.title:find('未知',1,true));assert.is_truthy(dialog.title:find('尚无记录',1,true))
    end)
    it('rechecks the original book and backend before dispatching an action',function()
        local moved,calls=false,0
        local plugin=Plugin:new{ui={menu={registerToMainMenu=function()end}}}
        plugin.dav_adapter={root=result.backend}
        plugin.progress={capture=function()return context end,_check_context=function()
            if moved then return nil,{code='CONFLICT',message='book changed'}end;return true
        end}
        plugin.hasRestorePoint=function()return false end
        plugin.onUploadCloudProgress=function()calls=calls+1 end
        Cloud.new=function()return {progress_operation=function(_,operation,_,_,done)
            assert.is_equal('query',operation);done(nil,result)
        end}end
        plugin:_cloud('query')
        local dialog=UI._window_stack[#UI._window_stack].widget
        assert.is_false(plugin.dav_busy)
        moved=true;dialog.buttons[1][1].callback();assert.is_equal(0,calls)
        UI:close(UI._window_stack[#UI._window_stack].widget)
        moved=false;plugin:_cloud('query');dialog=UI._window_stack[#UI._window_stack].widget
        plugin.dav_adapter={root='another backend'}
        dialog.buttons[1][1].callback();assert.is_equal(0,calls)
        UI:close(UI._window_stack[#UI._window_stack].widget)
        plugin:_cloud('query');dialog=UI._window_stack[#UI._window_stack].widget
        dialog.buttons[1][1].callback();assert.is_equal(1,calls)
    end)
    it('renders the comparison on the native screen',function()
        local dialog=CloudUI.query(result,context,{upload=function()end,download=function()end,
            refresh=function()end,undo=function()end})
        local screen=require('device').screen
        screen.bb:fill(require('ffi/blitbuffer').COLOR_WHITE)
        dialog:paintTo(screen.bb,0,0)
        local path=os.getenv('BPS_COMPARE_PREVIEW')
        if path then assert(screen:shot(path))end
    end)
end)
