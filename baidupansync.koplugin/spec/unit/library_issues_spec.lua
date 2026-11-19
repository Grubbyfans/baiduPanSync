describe('pending library management',function()
    local UI,CloudUI,Issues,baseline,result,selected
    setup(function()
        require('commonrequire');UI=require('ui/uimanager');CloudUI=require('ui/cloud_dialog')
        Issues=require('modules/library_issues')
    end)
    before_each(function()
        baseline={};for _,window in ipairs(UI._window_stack)do baseline[window.widget]=true end
        local id=string.rep('a',64)
        result={backend='http://test/sync/',backend_label='WebDAV · test/sync/',backend_id='fixture',
            entries={{incomplete=true,record={bookId=id,title='文件缺失的书籍',fileName='missing.epub',size=10,path='books/'..id..'.epub'}}},
            unpublished={{book_id=string.rep('b',64),path='books/'..string.rep('b',64)..'.epub',size=10,backend_id='fixture',book_stat={type='file',size=10}}},
            issues={{recoverable=true,path='metadata/'..id..'.json',message='文件缺失'},
                {path='metadata/'..string.rep('c',64)..'.json',book_id=string.rep('c',64),message='发布记录损坏',
                    cleanup_allowed=true,stat={type='file',size=1},backend_id='fixture'},
                {path='metadata/unknown.json',message='无法识别的发布记录'}}}
        selected=nil
    end)
    after_each(function()
        for i=#UI._window_stack,1,-1 do local w=UI._window_stack[i].widget;if not baseline[w]then UI:close(w)end end
    end)
    local function grid()
        return CloudUI.library(result,function()end,nil,nil,nil,nil,function(e)selected=e end,
            function(e)selected=e end,nil,nil,function(e)selected=e end)
    end
    it('groups all exceptions once and offers no destructive action for unknown names',function()
        local items=Issues.collect(result)
        assert.is_equal(4,#items);assert.is_truthy(items[1].repair);assert.is_truthy(items[2].entry)
        assert.is_truthy(items[3].cleanup);assert.is_nil(items[4].cleanup)
    end)
    it('shows reasons before dispatching explicit repair or cleanup',function()
        local shelf=grid();local list=shelf:pending()
        assert.is_nil(selected);list.buttons[1][1].callback()
        local details=UI._window_stack[#UI._window_stack].widget
        assert.is_truthy(details.title:find('原因',1,true));assert.is_equal('校验并补全发布',details.buttons[1][1].text)
        details.buttons[2][1].callback();assert.is_equal('unpublished',selected.kind)
    end)
    it('renders a native pending list with all categories',function()
        local list=grid():pending()
        local screen=require('device').screen
        screen.bb:fill(require('ffi/blitbuffer').COLOR_WHITE);list:paintTo(screen.bb,0,0)
        local path=os.getenv('BPS_PENDING_PREVIEW');if path then assert(screen:shot(path))end
        assert.is_equal(5,#list.buttons)
    end)
end)
