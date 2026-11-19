describe('compact cloud library controls',function()
    local UI,CloudUI
    setup(function()require('commonrequire');UI=require('ui/uimanager');CloudUI=require('ui/cloud_dialog')end)
    it('keeps only search refresh and management on the shelf and dispatches secondary menu actions',function()
        local count={scan=0,switch=0,refresh=0,recover=0,diagnostics=0}
        local result={entries={},issues={},backend='http://test/sync/',backend_label='百度网盘 · 我的账户',
            cached=true,updated_at=os.time(),pending_publications=2,
            on_check_local=function()count.scan=count.scan+1 end,
            on_recover_publications=function()count.recover=count.recover+1 end,
            on_diagnostics=function()count.diagnostics=count.diagnostics+1 end}
        for i=1,9 do
            result.entries[i]={record={bookId='书籍'..i,fileName='书籍'..i..'.epub',title='书籍'..i,size=1024*i},
                local_path=i%3==0 and ('/books/书籍'..i..'.epub')or nil}
        end
        local grid=CloudUI.library(result,function()end,nil,nil,nil,nil,nil,nil,
            function()count.refresh=count.refresh+1 end,function()count.switch=count.switch+1 end)
        assert.is_equal(1,#grid.toolbar_buttons);assert.is_equal(3,#grid.toolbar_buttons[1])
        assert.is_equal('搜索',grid.toolbar_buttons[1][1].text)
        assert.is_equal('主动更新书库',grid.toolbar_buttons[1][2].text)
        grid.toolbar_buttons[1][2].callback();assert.is_equal(1,count.refresh)
        for label,key in pairs({['检查本机书籍']='scan',['切换后端']='switch',['补全书库列表（2）']='recover',['最近任务诊断']='diagnostics'})do
            grid.toolbar_buttons[1][3].callback()
            local dialog=UI._window_stack[#UI._window_stack].widget;local selected
            for _,row in ipairs(dialog.buttons)do if row[1].text==label then selected=row[1]end end
            assert.is_truthy(selected,label);selected.callback();assert.is_equal(1,count[key])
        end
        local path=os.getenv('BPS_SHELF_PREVIEW')
        if path then local Screen=require('device').screen;Screen.bb:fill(require('ffi/blitbuffer').COLOR_WHITE);grid:paintTo(Screen.bb,0,0);assert(Screen:shot(path))end
        UI:close(grid)
    end)
end)
