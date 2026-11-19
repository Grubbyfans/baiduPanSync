describe('persistent plugin page',function()
    local UI,Plugin,Buttons,CloudUI,Screen,plugin,shown,baseline
    local function visible(widget)
        for _,window in ipairs(UI._window_stack)do if window.widget==widget then return true end end
        return false
    end
    setup(function()
        require('commonrequire')
        UI=require('ui/uimanager');Buttons=require('ui/widget/buttondialog');CloudUI=require('ui/cloud_dialog')
        Plugin=dofile(os.getenv('BPS_PLUGIN_ROOT')..'/main.lua');Screen=require('device').screen
    end)
    before_each(function()
        plugin=Plugin:new{ui={menu={registerToMainMenu=function()end}}}
        plugin.dav_adapter={};plugin.dav_profile={root_url='http://192.168.1.2:8080/sync/'}
        plugin.isCurrentBookSupported=function()return true end
        plugin.hasRestorePoint=function()return false end
        shown={}
        baseline={}
        for _,window in ipairs(UI._window_stack)do baseline[window.widget]=true end
    end)
    after_each(function()
        plugin:closeHome()
        for i=#UI._window_stack,1,-1 do
            local window=UI._window_stack[i]
            if window and not baseline[window.widget]then UI:close(window.widget)end
        end
    end)
    it('opens one full-screen page and leaves it behind operation dialogs',function()
        local entry=require('ui/menu').build(plugin)
        local closed=false
        entry.callback({closeMenu=function()closed=true end})
        local page=plugin.home_page
        assert.is_true(closed);assert.is_true(visible(page))
        plugin:showHome();assert.is_equal(page,plugin.home_page)
        plugin.onQueryCloudProgress=function()
            local dialog=Buttons:new{title='result',buttons={{{text='OK'}}}}
            shown[#shown+1]=dialog;UI:show(dialog)
        end
        page:onMenuSelect(page.item_table[3])
        assert.is_true(visible(page));assert.is_true(visible(shown[1]))
        UI:close(shown[1]);assert.is_equal(page,plugin.home_page);assert.is_true(visible(page))
    end)
    it('refreshes configured state and prevents dispatch while a task is busy',function()
        plugin:showHome();local page=plugin.home_page
        local called=0
        plugin.onUploadBook=function()called=called+1 end
        plugin.dav_busy=true;page:refresh()
        assert.is_false(page.item_table[2].select_enabled)
        page:onMenuSelect(page.item_table[2]);assert.is_equal(0,called)
        plugin.dav_busy=false;plugin:refreshHome()
        page:onMenuSelect(page.item_table[2]);assert.is_equal(1,called)
        plugin.dav_adapter=nil;plugin.dav_profile=nil;plugin:refreshHome()
        assert.is_false(page.item_table[1].select_enabled)
        assert.is_true(page.item_table[4].select_enabled)
        assert.is_truthy(page.item_table[4].text:find('请先配置',1,true))
    end)
    it('does not reopen a page after the user leaves or after a document opens',function()
        plugin:showHome();local page=plugin.home_page
        page:onClose()
        assert.is_nil(plugin.home_page);assert.is_false(visible(page))
        plugin:refreshHome();assert.is_nil(plugin.home_page)
        plugin:showHome();page=plugin.home_page
        page:onShowingReader();assert.is_nil(plugin.home_page);assert.is_false(visible(page))
    end)
    it('keeps the library and current page open when choosing a book to download',function()
        plugin:showHome();local home=plugin.home_page
        local result={entries={},issues={},backend='http://test/sync/'}
        for i=1,12 do result.entries[i]={record={title=string.format("Book %02d",i),fileName='book'..i..'.epub',bookId=string.rep('a',64),size=100}}end
        local selected
        local function on_show(dialog)plugin.library_dialog=dialog end
        local function on_close(dialog)if plugin.library_dialog==dialog then plugin.library_dialog=nil end end
        local first=CloudUI.library(result,function(entry)selected=entry end,nil,on_show,on_close)
        -- Explicitly paginate to the second page, then choose its book.
        UI:close(first)
        local second=CloudUI.library(result,function(entry)selected=entry end,2,on_show,on_close)
        second:select(second.visible_entries[1])
        assert.is_equal(result.entries[second.layout_info.count+1],selected)
        assert.is_true(visible(second));assert.is_true(visible(home))
        second:close()
        assert.is_nil(plugin.library_dialog);assert.is_true(visible(home))
    end)
    it('renders the native page at screen size',function()
        plugin.ui.document={file='/books/三国演义.epub'}
        plugin:showHome();local page=plugin.home_page
        assert.is_equal(Screen:getWidth(),page.dimen.w)
        assert.is_equal(Screen:getHeight(),page.dimen.h)
        Screen.bb:fill(require('ffi/blitbuffer').COLOR_WHITE)
        page:paintTo(Screen.bb,0,0)
        local output=os.getenv('BPS_HOME_PREVIEW')
        if output then assert(Screen:shot(output)) end
    end)
    it('keeps backend identity visible on the home page and library',function()
        plugin:showHome()
        assert.is_truthy(plugin.home_page:status():find('WebDAV · 192.168.1.2:8080/sync/',1,true))
        local switched,refreshed=0,0
        local result={backend='http://test/sync/',backend_label='百度网盘 · 我的账户',entries={},issues={}}
        local grid=CloudUI.library(result,function()end,nil,nil,nil,nil,nil,nil,function()refreshed=refreshed+1 end,function()switched=switched+1 end)
        assert.is_equal(result.backend_label,grid.result.backend_label)
        grid.toolbar_buttons[1][3].callback();assert.is_equal(1,refreshed)
        grid.toolbar_buttons[1][4].callback();assert.is_equal(1,switched)
        Screen.bb:fill(require('ffi/blitbuffer').COLOR_WHITE);grid:paintTo(Screen.bb,0,0)
        local output=os.getenv('BPS_LIBRARY_PREVIEW')
        if output then assert(Screen:shot(output))end
        UI:close(grid)
    end)
    it('returns to the same page after saving the actual WebDAV configuration dialog',function()
        plugin:showHome();local home=plugin.home_page
        home:onMenuSelect(home.item_table[4])
        home:onMenuSelect(home.item_table[2])
        local input
        for _,window in ipairs(UI._window_stack)do
            if window.widget.title=='WebDAV 配置'then input=window.widget end
        end
        assert.is_truthy(input);assert.is_true(visible(home))
        input.getFields=function()return {'http://192.168.1.2:8080/sync/','test-user','test-password',''}end
        local saved
        plugin.backend_store.save=function(_,profile)saved=profile;return true end
        input.buttons[1][2].callback()
        assert.is_truthy(saved);assert.is_false(visible(input))
        assert.is_equal(home,plugin.home_page);assert.is_true(visible(home))
        assert.is_true(home.item_table[3].select_enabled)
        assert.is_truthy(home.item_table[2].text:find('修改',1,true))
    end)

end)
