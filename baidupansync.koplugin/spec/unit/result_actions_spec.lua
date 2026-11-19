describe('actionable task results',function()
    local UI,Dialog,CloudUI,Cloud,Plugin,BaiduUI,Probe,original,baseline,plugin,reply,failure,writes
    setup(function()
        require('commonrequire')
        UI=require('ui/uimanager');Dialog=require('ui/progress_dialog');CloudUI=require('ui/cloud_dialog')
        Cloud=require('modules/cloud_service');BaiduUI=require('ui/baidu_dialog');Probe=require('modules/baidu_probe')
        Plugin=dofile(os.getenv('BPS_PLUGIN_ROOT')..'/main.lua')
    end)
    before_each(function()
        original={new=Cloud.new,authorize=BaiduUI.authorize,switch_backend=BaiduUI.switch_backend,probe=Probe.run}
        baseline={};for _,window in ipairs(UI._window_stack)do baseline[window.widget]=true end
        plugin=Plugin:new{ui={menu={registerToMainMenu=function()end}}}
        plugin.dav_adapter={root='http://test/sync/'};plugin.hasRestorePoint=function()return false end
        plugin.progress={capture=function()return {book={file_path='/books/test.epub',title='Test'},progress={percent=0.3}}end,
            _check_context=function()return true end}
        writes=0;failure=nil;reply={}
        Cloud.new=function()return {
            upload_book=function(_,_,_,done)writes=writes+1;done(failure,reply)end,
            progress_operation=function(_,_,_,_,done)writes=writes+1;done(failure,reply)end,
        }end
    end)
    after_each(function()
        Cloud.new=original.new;BaiduUI.authorize=original.authorize;BaiduUI.switch_backend=original.switch_backend;Probe.run=original.probe
        for i=#UI._window_stack,1,-1 do
            local widget=UI._window_stack[i].widget
            if not baseline[widget]then UI:close(widget)end
        end
    end)
    local function top()return UI._window_stack[#UI._window_stack].widget end
    it('keeps results until a choice and invokes the chosen action only once',function()
        local called=0
        local dialog=Dialog.result('完成','结果已核验',{{text='下一步',callback=function()called=called+1 end}})
        assert.is_false(dialog.dismissable);assert.is_nil(dialog.timeout);assert.is_equal(0,called)
        dialog.buttons[1][1].callback();dialog.buttons[1][1].callback();assert.is_equal(1,called)
    end)
    it('offers progress upload after book publication without uploading automatically',function()
        local progress=0;plugin.onUploadCloudProgress=function()progress=progress+1 end
        plugin:_cloud('upload_book')
        local dialog=top();assert.is_equal('上传阅读进度',dialog.buttons[1][1].text)
        assert.is_equal(0,progress);assert.is_false(plugin.dav_busy)
        dialog.buttons[1][1].callback();assert.is_equal(1,progress);assert.is_equal(1,writes)
    end)
    it('blocks an old result button after changing backend',function()
        local called=0;plugin.onCloudLibrary=function()called=called+1 end
        plugin:_cloud('upload_book');local dialog=top()
        plugin.dav_adapter={root='http://another/sync/'}
        dialog.buttons[2][1].callback();assert.is_equal(0,called)
    end)
    it('offers a read instead of repeating an uncertain write',function()
        local queried=0;plugin.onQueryCloudProgress=function()queried=queried+1 end
        failure={code='UNCERTAIN',message='remote result unknown',outcome='uncertain'}
        plugin:_cloud('upload')
        local dialog=top();assert.is_equal('查看进度对比',dialog.buttons[1][1].text)
        dialog.buttons[1][1].callback();assert.is_equal(1,queried);assert.is_equal(1,writes)
    end)
    it('offers catalog-only completion for a confirmed EPUB and retry-upload for unconfirmed EPUB',function()
        plugin.hasRestorePoint=function()return false end
        plugin:_cloud('upload_book')
        UI:close(top())
        failure={code='UNCERTAIN',message='catalog offline',detail={stage='catalog',record={bookId='test'}}}
        plugin:_cloud('upload_book')
        assert.is_equal('补全书库列表',top().buttons[1][1].text)
        UI:close(top())
        failure={code='NETWORK',message='EPUB offline',detail={stage='epub'}}
        plugin:_cloud('upload_book')
        assert.is_equal('重新上传书籍',top().buttons[1][1].text)
    end)
    it('offers undo after applying remote progress',function()
        local undone=0;plugin.onUndoRestore=function()undone=undone+1 end
        plugin:_cloud('download');local dialog=top()
        assert.is_equal('撤销上次应用',dialog.buttons[1][1].text)
        dialog.buttons[1][1].callback();assert.is_equal(1,undone)
    end)
    it('provides reauthorization for an expired account without starting it automatically',function()
        local authorized=0;BaiduUI.authorize=function()authorized=authorized+1 end
        plugin.active_backend='baidu';plugin._baiduBackend=function()return nil,{code='AUTH',message='expired'}end
        plugin:_cloud('query');local dialog=top()
        assert.is_equal('重新授权',dialog.buttons[1][1].text);assert.is_equal(0,authorized)
        dialog.buttons[1][1].callback();assert.is_equal(1,authorized)
    end)
    it('offers backend selection after successful Baidu verification',function()
        local selected,saved=0,false
        plugin.baidu_store={load=function()return {app_dir='/apps/test',app_key='app',user_id='123',access_token='token'}end,
            save=function()saved=true;return true end}
        Probe.run=function(_,done)done(nil,{directory='/apps/test/probe'})end
        BaiduUI.switch_backend=function()selected=selected+1 end
        BaiduUI.probe(plugin);assert.is_true(saved);assert.is_equal(0,selected)
        top().buttons[1][1].callback();assert.is_equal(1,selected)
    end)
    it('does not offer to open a download that requires restart',function()
        local opened=0
        local dialog=CloudUI.downloaded({path='/books/test.epub',restart_required=true},function()opened=opened+1 end)
        assert.is_equal(1,#dialog.buttons);assert.is_equal('关闭',dialog.buttons[1][1].text)
        assert.is_truthy(dialog.title:find('重启 KOReader',1,true));assert.is_equal(0,opened)
    end)
    it('renders the native publication result with its next actions',function()
        plugin:_cloud('upload_book');local dialog=top()
        local screen=require('device').screen
        screen.bb:fill(require('ffi/blitbuffer').COLOR_WHITE);dialog:paintTo(screen.bb,0,0)
        local path=os.getenv('BPS_RESULT_PREVIEW');if path then assert(screen:shot(path))end
    end)
    it('keeps actions on screen and full details available for long errors',function()
        local text=string.rep('很长的错误说明和云端路径\n',60)
        local dialog=Dialog.result('操作未完成',text,{{text='查询状态',callback=function()end}})
        assert.is_true(dialog.movable:getSize().h<=require('device').screen:getHeight())
        assert.is_equal('查询状态',dialog.buttons[1][1].text)
        assert.is_equal('查看完整信息',dialog.buttons[2][1].text)
        dialog.buttons[2][1].callback();assert.is_equal(text,top().text)
    end)
end)
