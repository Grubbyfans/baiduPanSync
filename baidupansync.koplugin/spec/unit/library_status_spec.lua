describe('visible library cache status',function()
    local Status,UI,CloudUI
    setup(function()require('commonrequire');Status=require('ui/library_status');UI=require('ui/uimanager');CloudUI=require('ui/cloud_dialog')end)
    it('distinguishes cache, in-flight refresh and latest remote data with last successful time',function()
        local v={cached=true,updated_at=1795000000}
        assert.is_truthy(Status.text(v):find('本机缓存',1,true))
        assert.is_truthy(Status.text(v):find(os.date('%Y-%m-%d %H:%M',v.updated_at),1,true))
        v.refreshing=true;assert.is_truthy(Status.text(v):find('正在更新',1,true))
        v.refreshing=nil;v.cached=nil;assert.is_truthy(Status.text(v):find('云端最新列表',1,true))
        v.updated_at=nil;assert.is_truthy(Status.text(v):find('尚未成功获取',1,true))
    end)
    it('keeps failure and retry instructions visible without replacing the old time',function()
        local v={entries={},issues={},backend='fixture',cached=true,updated_at=1795000000,refresh_error='offline'}
        local grid=CloudUI.library(v,function()end)
        assert.is_truthy(grid.cache_status_text:find('仍显示旧列表',1,true))
        assert.is_truthy(grid.cache_status_text:find('主动更新书库',1,true))
        assert.is_truthy(grid.cache_status_text:find(os.date('%Y-%m-%d %H:%M',v.updated_at),1,true))
        local path=os.getenv('BPS_CACHE_PREVIEW')
        if path then local Screen=require('device').screen;Screen.bb:fill(require('ffi/blitbuffer').COLOR_WHITE);grid:paintTo(Screen.bb,0,0);assert(Screen:shot(path))end
        UI:close(grid)
    end)
end)
