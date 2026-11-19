--[[--
BaiduPanSync 0.10.1: manual WebDAV/Baidu EPUB and reading-progress synchronization.
D/E/F use CloudService with fixed backend snapshots.
Baidu provides OOB authorization, streamed book transfers and manual progress sync.
]]

local DataStorage = require("datastorage")
local Device = require("device")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local _ = require("gettext")

local BookIdentity = require("modules/book_identity")
local ConfigStore = require("modules/config_store")
local LocalStore = require("modules/storage")
local ProgressService = require("modules/progress")
local SyncState = require("modules/sync_state")
local Dialog = require("ui/progress_dialog")
local Menu = require("ui/menu")

local T = ffiUtil.template
local VERSION = "0.10.1"

local BaiduPanSync = WidgetContainer:extend{
    name = "baidupansync",
    is_doc_only = false,
    version = VERSION,
}

function BaiduPanSync:init()
    self.settings_dir = DataStorage:getSettingsDir() .. "/baidupansync"
    self.store = LocalStore:new{ dir = self.settings_dir }
    self.config = ConfigStore:new{ dir = self.settings_dir }
    self.state = SyncState:new{ dir = self.settings_dir }
    self.identity = BookIdentity:new{ dir = self.settings_dir }
    self.progress = ProgressService:new{
        reader_ui = self.ui,
        identity = self.identity,
        store = self.store,
        event = Event,
    }
    self.backend_store = require("modules/backend_store"):new{dir=self.settings_dir, config=self.config}
    self.baidu_store = require('modules/baidu_store'):new{dir=self.settings_dir}
    local config_state=self.config:_read()
    self.active_backend=config_state and config_state.data.activeBackendType or 'webdav'
    self.dav_profile, self.dav_load_error = self.backend_store:load()
    if self.dav_profile then
        self.dav_adapter, self.dav_load_error = require("modules/webdav"):new(self.dav_profile)
    end
    self.ui.menu:registerToMainMenu(self)
end

function BaiduPanSync:addToMainMenu(menu_items)
    menu_items.baidupansync = Menu.build(self)
end

function BaiduPanSync:showHome()
    if self.home_page then return self:refreshHome() end
    local page=require("ui/home_page"):new{plugin=self}
    self.home_page=page
    UIManager:show(page)
end

function BaiduPanSync:refreshHome()
    if self.home_page then self.home_page:refresh() end
end

function BaiduPanSync:closeHome()
    if self.library_dialog then UIManager:close(self.library_dialog) end
    if self.home_page then UIManager:close(self.home_page) end
end

function BaiduPanSync:onCloseDocument()
    if self.baidu_session then self.baidu_session:stop('cancelled') end
    self:closeHome()
end
function BaiduPanSync:onSuspend()
    if self.baidu_session then self.baidu_session:stop('cancelled') end
end
function BaiduPanSync:onNetworkDisconnected()
    if self.baidu_session then self.baidu_session:stop('network_changed') end
end

function BaiduPanSync:isCurrentBookSupported()
    return self.progress:is_supported() and true or false
end

function BaiduPanSync:hasRestorePoint()
    return self.progress:has_restore_point()
end
function BaiduPanSync:_baiduBackend()
    local p,e=self.baidu_store:load();if e then return nil,e end
    if not p or not p.user_id then return nil,require('modules/errors').new('AUTH','请先配置百度应用并完成扫码授权') end
    if type(p.expires_at)~='number' or os.time()>=p.expires_at-30 then
        return nil,require('modules/errors').new('AUTH','百度授权已过期，请重新授权并运行连接测试')
    end
    local api,err=require('modules/baidu_api'):new(p);if not api then return nil,err end
    if api.backend_id~=p.backend_id or type(p.last_probe)~='table' or p.last_probe.backend_id~=api.backend_id then
        return nil,require('modules/errors').new('AUTH','请先在百度网盘设置中通过测试文件上传与下载验证')
    end
    return api
end
function BaiduPanSync:hasUsableBaidu()
    return self:_baiduBackend()~=nil
end

-- Builds hash UI callbacks. The progress dialog only appears on a cache miss;
-- cache hits complete synchronously without any dialog.
function BaiduPanSync:_hash_opts()
    local hash_ui
    return {
        on_hash_start = function(total)
            hash_ui = Dialog.start_hash_progress(total)
        end,
        on_hash_finish = function()
            if hash_ui then
                hash_ui:close()
                hash_ui = nil
            end
        end,
        on_progress = function(done)
            if hash_ui then hash_ui:report(done) end
        end,
        is_cancelled = function()
            return hash_ui ~= nil and hash_ui:is_cancelled()
        end,
        schedule = function(callback)
            UIManager:scheduleIn(0, callback)
        end,
    }
end

function BaiduPanSync:onUndoRestore()
    if self.undo_busy or self.dav_busy or self.baidu_busy then return Dialog.info("已有任务正在进行，请稍候。") end
    local restore_point, rp_err = self.store:get_restore_point()
    if rp_err then return Dialog.error(rp_err) end
    if not restore_point then
        return Dialog.info(_("没有可撤销的进度恢复点。"))
    end
    Dialog.confirm_undo(restore_point, function()
        if self.undo_busy or self.dav_busy or self.baidu_busy then return Dialog.info("已有任务正在进行，请稍候。") end
        self.undo_busy = true
        self.progress:undo(function(undo_err, result)
            self.undo_busy = false
            self:refreshHome()
            if undo_err then
                local extra
                if result and result.rollback then
                    extra = _("已尝试回到撤销前的位置。")
                end
                return Dialog.error(undo_err, extra)
            end
            if result and result.no_navigation then
                return Dialog.info(_("当前位置已在恢复点，无需跳转。"))
            end
            local message = T(_("已撤销上次进度恢复：%1"),
                Dialog.percent_text(restore_point.position.percent))
            if result and result.warning then
                message = message .. "\n" .. _("恢复点清理失败，可稍后重试。")
            end
            Dialog.info(message)
        end)
    end)
end

function BaiduPanSync:_connectionActions(mode,auth)
    return {{text=auth and mode=='baidu' and '重新授权' or '检查连接设置',callback=function()
        if (self.active_backend or 'webdav')~=mode then
            return Dialog.error(require('modules/errors').new('CONFLICT','当前后端已变化，请从主页重新操作'))
        end
        if mode=='baidu' then
            local dialog=require('ui/baidu_dialog')
            if auth then dialog.authorize(self)else dialog.show(self)end
        else require('ui/backend_dialog').configure(self)end
    end}}
end

function BaiduPanSync:_cloud(operation, entry, force_refresh)
    if self.dav_busy or self.undo_busy or self.baidu_busy then return Dialog.info("已有任务正在进行，请稍候。") end
    local mode=self.active_backend or 'webdav'
    local backend
    if mode=='baidu' then
        local err;backend,err=self:_baiduBackend()
        if not backend then return Dialog.error(err,nil,self:_connectionActions(mode,err.code=='AUTH')) end
    elseif mode=='webdav' then
        if self.dav_load_error then return Dialog.error(self.dav_load_error) end
        if not self.dav_adapter then return Dialog.info("请先配置 WebDAV。") end
        backend=self.dav_adapter
    else return Dialog.info('当前后端类型无效，请在连接设置中重新选择。') end
    local context
    if operation~="list" and operation~="download_book" and operation~="delete_book" then
        local e
        context,e=self.progress:capture()
        if not context then return Dialog.error(e) end
    end
    local cloud=require("modules/cloud_service"):new{backend=backend,identity=self.identity,progress=self.progress,
        state=self.state,config=self.config,temp_dir=self.settings_dir.."/transfers",device_label=Device.model or "koreader"}
    local cloud_dialog=require("ui/cloud_dialog")
    local backend_label=require('ui/backend_label').for_backend(backend)
    local tracker
    if operation=='upload_book' or operation=='download_book' then
        tracker=require('ui/task_progress').new(operation,backend_label)
    end
    local opts=tracker and {
        schedule=function(cb)UIManager:scheduleIn(0,cb)end,
        is_cancelled=function()return tracker:is_cancelled()end,
        on_hash_start=function(total)tracker:hash_start(total)end,
        on_hash_finish=function()end,
        on_progress=function(count,total)tracker:report(count,total)end,
        on_transfer=function(count,total)tracker:report(count,total)end,
        task_progress=tracker,
    } or self:_hash_opts()
    local logger=require('logger')
    logger.info('BaiduPanSync',VERSION,mode,operation,'start',context and context.book.size or 0)
    opts.on_state=function(state)
        logger.info('BaiduPanSync',VERSION,mode,operation,'state',state)
        if tracker then tracker:state(state)end
    end
    opts.on_phase=function(phase)
        logger.info('BaiduPanSync',VERSION,mode,operation,'phase',phase)
        if tracker then tracker:phase(phase)end
    end
    opts.guard=function()
        if (self.active_backend or 'webdav')~=mode or (mode=='webdav' and self.dav_adapter~=backend) then
            return nil,require("modules/errors").new("CONFLICT","后端配置已变化")
        end
        if mode=='baidu' then
            local p,e=self.baidu_store:load();if e then return nil,e end
            if not p or p.backend_id~=backend.backend_id or p.access_token~=backend.profile.access_token
                or p.cafile~=backend.profile.cafile or p.app_dir~=backend.profile.app_dir then
                return nil,require('modules/errors').new('CONFLICT','百度账户或配置已变化，请重新开始')
            end
        end
        return true
    end
    opts.confirm=function(info,done)info.backend_label=backend_label;cloud_dialog.confirm(info,done)end
    if operation=='upload_book' then opts.make_cover=require('modules/book_cover').extract end
    local scan_ui
    local hash_cancelled=opts.is_cancelled
    opts.is_cancelled=function()return (scan_ui and scan_ui:is_cancelled()) or hash_cancelled()end
    opts.on_scan_start=function()
        if tracker then tracker:set_stage(2,'检查根目录及子目录的同名书籍')
        else scan_ui=Dialog.start_scan_progress()end
    end
    opts.on_scan_finish=function()if scan_ui then scan_ui:close()end end
    opts.home_dir=G_reader_settings:readSetting("home_dir")
    opts.get_home=function()return G_reader_settings:readSetting("home_dir")end
    opts.current_path=function()
        local reader=require("apps/reader/readerui").instance
        local document=reader and reader.document or self.ui.document
        return document and document.file
    end
    opts.backup_metadata=require("modules/local_library").backup_metadata
    backend.operation_opts=opts
    self.dav_busy=true
    local cache=require('modules/library_cache'):new(self.settings_dir..'/cache')
    local cached=operation=='list' and cache:load(backend.backend_id,backend.root) or nil
    local view=self.library_dialog
    if view and (view.closed or view.result.backend_id~=backend.backend_id) then view=nil end
    local function show_library(result)
        result.backend_label=backend_label
        result.load_covers=function(grid)
            if grid.cover_loading then return end
            grid.cover_loading=true
            local page=grid.page
            require('modules/async').run(function()
                for _,selected in ipairs(grid.visible_entries or {}) do
                    if grid.closed then break end
                    local record=selected.record
                    if record.coverPath and not selected.coverPng then
                        local cover=cache:load_cover(backend.backend_id,record)
                        if not cover then
                            local err,raw=require('modules/async').await(function(cb)backend:download(record.coverPath,cb)end)
                            if not err and type(raw)=='string' then
                                local ok,value=pcall(require('json').decode,raw)
                                if ok and type(value)=='table' and require('modules/book_cover').decode(value.coverPng) then
                                    cover=value.coverPng;cache:save_cover(backend.backend_id,record,cover)
                                end
                            end
                        end
                        if cover then selected.coverPng=cover end
                    end
                end
            end,function()
                grid.cover_loading=false
                if not grid.closed and grid.result==result then
                    grid:rebuild(true)
                    if grid.page~=page then result.load_covers(grid)end
                end
            end)
        end
        if view and not view.closed then view:updateResult(result);return view end
        if self.library_dialog then UIManager:close(self.library_dialog) end
        view=cloud_dialog.library(result,function(selected)self:_cloud('download_book',selected)end,nil,function(dialog)
            self.library_dialog=dialog
        end,function(dialog)
            if self.library_dialog==dialog then self.library_dialog=nil end
        end,nil,function(selected)self:_cloud('delete_book',selected)end,
            nil,function()self:_cloud('list',nil,true)end,
            function()require('ui/baidu_dialog').switch_backend(self)end,
            nil)
        return view
    end
    if cached and not force_refresh and cache:fresh(cached) then
        self.dav_busy=false;backend.operation_opts=nil
        return show_library(cached)
    end
    if cached then cached.refreshing=true;show_library(cached) end
    local function checked(action,needs_book)return function()
        local ok,err=opts.guard()
        if ok and needs_book then ok,err=self.progress:_check_context(context) end
        if not ok then return Dialog.error(err) end
        action()
    end end
    local library_action={text='查看云端书库',callback=checked(function()self:onCloudLibrary()end)}
    local compare_action={text='查看进度对比',callback=checked(function()self:onQueryCloudProgress()end,true)}
    local function show_error(err)
        if err.code=='CANCELLED' then return Dialog.error(err) end
        local actions
        if err.code=='AUTH' then actions=self:_connectionActions(mode,true)
        elseif err.code=='UNCERTAIN' or err.outcome=='uncertain' then
            actions={(context and operation~='upload_book') and compare_action or library_action}
        elseif err.code=='NETWORK' or err.code=='TLS' then
            actions=self:_connectionActions(mode,false)
            if operation=='query' then table.insert(actions,1,compare_action) end
        else actions={library_action} end
        return Dialog.error(err,backend_label,actions)
    end
    local function completed(e,result)
        if scan_ui then scan_ui:close() end
        if tracker then tracker:close()end
        if backend.operation_opts==opts then backend.operation_opts=nil end
        self.dav_busy=false
        if e then logger.warn('BaiduPanSync',VERSION,mode,operation,'finished',e.code,e.message)
        else logger.info('BaiduPanSync',VERSION,mode,operation,'finished','success') end
        if result and result.library then
            local ok,saved=pcall(cache.save,cache,backend.backend_id,result.library)
            if not ok or not saved then logger.warn('BaiduPanSync: library cache could not be saved')end
            if view and not view.closed then show_library(result.library)end
        elseif e and (operation=='upload_book' or operation=='delete_book') and e.code~='CANCELLED' then
            cache:invalidate(backend.backend_id)
        end
        self:refreshHome()
        if operation=='list' then
            if not e then
                local ok,saved=pcall(cache.save,cache,backend.backend_id,result)
                if not ok or not saved then logger.warn('BaiduPanSync: library cache could not be saved') end
            end
            if view and view.closed then return end
            if e then
                if cached and view then cached.refreshing=nil;cached.refresh_error=e.message;view:updateResult(cached) end
                return show_error(e)
            end
            return show_library(result)
        end
        if operation=='delete_book' then
            if not e or e.code~='CANCELLED' then
                if self.library_dialog then UIManager:close(self.library_dialog);self.library_dialog=nil end
            end
            if e then return show_error(e) end
            return Dialog.result('云端删除完成',backend_label..'\n云端书籍、书库记录和云端进度已删除。\n本机文件与阅读位置保留。',{library_action})
        end
        if e then return show_error(e) end
        if operation=="query" then
            result.backend_label=backend_label
            return cloud_dialog.query(result,context,{
                upload=checked(function()self:onUploadCloudProgress()end,true),
                download=checked(function()self:onDownloadCloudProgress()end,true),
                refresh=checked(function()self:onQueryCloudProgress()end,true),
                undo=self:hasRestorePoint() and checked(function()self:onUndoRestore()end,true) or nil,
            })
        elseif operation=="download_book" then
            return cloud_dialog.downloaded(result,function(file)
                self:closeHome()
                require("apps/reader/readerui"):showReader(file)
            end,library_action.callback)
        elseif operation=="upload_book" then
            if result.skipped then return Dialog.info('已跳过。') end
            return Dialog.result('书籍发布完成',backend_label..'\n书籍和书库列表已提交。原有阅读进度保留，未自动上传。'..(result.warning and ('\n'..result.warning) or ''),{
                {text='上传阅读进度',callback=checked(function()self:onUploadCloudProgress()end,true)},library_action})
        elseif operation=="upload" then
            return Dialog.result('阅读进度上传完成',backend_label..'\n'..
                '阅读进度已提交。',{compare_action})
        else return Dialog.result('云端进度已应用',backend_label..'\n已保留恢复点，可撤销本次恢复。',{
            {text='撤销上次应用',callback=checked(function()self:onUndoRestore()end,true)},compare_action}) end
    end
    if operation=="list" then
        if force_refresh and backend.invalidate_link then backend:invalidate_link('library.json')end
        if cached then UIManager:scheduleIn(0.1,function()
            if view.closed then return completed(require('modules/errors').new('CANCELLED','已关闭书库，取消刷新')) end
            cloud:list(opts,completed)
        end)
        else cloud:list(opts,completed) end
    elseif operation=="download_book" then cloud:download_book(entry,opts,completed)
    elseif operation=="delete_book" then cloud:delete_book(entry,opts,completed)
    elseif operation=="upload_book" then cloud:upload_book(context,opts,completed)
    else cloud:progress_operation(operation,context,opts,completed) end
end
function BaiduPanSync:onUploadCloudProgress()self:_cloud("upload")end
function BaiduPanSync:onQueryCloudProgress()self:_cloud("query")end
function BaiduPanSync:onDownloadCloudProgress()self:_cloud("download")end
function BaiduPanSync:onUploadBook()self:_cloud("upload_book")end
function BaiduPanSync:onCloudLibrary()self:_cloud("list")end

return BaiduPanSync
