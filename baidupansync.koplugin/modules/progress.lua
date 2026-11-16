--[[--
ProgressService (Stage A): read the current EPUB position, navigate, verify and
undo, without any remote backend.

Design notes from the spec and from the verified KOReader source:
- positions come from ReaderRolling:getLastProgress(), never from KOSync;
- percent is optional and is dropped when it is not a finite 0..1 number;
- ReaderRolling:onGotoXPointer() is synchronous but there is no documented
  "rendering finished" event, so success is verified by reading the document
  engine's actual XPointer after the jump (never by trusting rolling.xpointer);
- equivalent locations are compared by resolving both XPointers to pages. In
  page mode that is the navigation contract; in scroll mode the check is
  page-level only and is reported as such;
- the restore point is persisted before the jump; a failed or unverified
  navigation is rolled back and is never reported as success;
- the service has no UI and no HTTP dependencies, and all time/scheduling/event
  dependencies are injectable for tests.
]]

local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local Errors = require("modules/errors")
local ProgressRecord = require("modules/progress_record")

local ProgressService = {}
ProgressService.__index = ProgressService

local DEFAULT_TIMEOUT_MS = 3000
local DEFAULT_POLL_MS = 100

local function default_now_ms()
    local seconds, micros = ffiUtil.gettime()
    return seconds * 1000 + micros / 1000
end

local function default_schedule(delay_ms, callback)
    require("ui/uimanager"):scheduleIn(delay_ms / 1000, callback)
end

local function sanitize_percent(value)
    if type(value) ~= "number" then return nil end
    if value ~= value or value == math.huge or value == -math.huge then return nil end
    if value < 0 or value > 1 then return nil end
    return value
end

local function clean_title(value)
    if type(value) ~= "string" or value == "" then return nil end
    if #value > ProgressRecord.MAX_TEXT_BYTES then return nil end
    if value:find("%c") then return nil end
    if not ProgressRecord.is_valid_utf8(value) then return nil end
    return value
end

--- @tparam table o {
--   reader_ui=ReaderUI, store=LocalStore,
--   event=<ui/event module>, schedule=function(delay_ms, cb),
--   now_ms=function(), os_time=function(),
--   timeout_ms=number, poll_ms=number }
function ProgressService:new(o)
    o = o or {}
    if not o.reader_ui then error("ProgressService requires reader_ui") end
    if not o.store then error("ProgressService requires store") end
    return setmetatable({
        reader_ui = o.reader_ui,
        store = o.store,
        event = o.event,
        schedule = o.schedule or default_schedule,
        now_ms = o.now_ms or default_now_ms,
        os_time = o.os_time or os.time,
        timeout_ms = o.timeout_ms or DEFAULT_TIMEOUT_MS,
        poll_ms = o.poll_ms or DEFAULT_POLL_MS,
    }, self)
end

function ProgressService:_document()
    local doc = self.reader_ui and self.reader_ui.document
    if not doc then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT, "当前没有打开的文档")
    end
    return doc
end

function ProgressService:_document_format(doc)
    local ok, format = pcall(function() return doc:getDocumentFormat() end)
    if ok and type(format) == "string" and format ~= "" then
        return format:lower()
    end
    return nil
end

-- Returns true, or false plus a user-facing reason. Fixed-layout documents
-- (has_pages) cannot provide a reflowable XPointer and are out of scope.
-- When the engine reports a format, it is authoritative; the file extension is
-- only a fallback for engines that do not expose one.
function ProgressService:_is_supported(doc)
    if doc.info and doc.info.has_pages then
        return false, "仅支持流式 EPUB，当前文档为固定版式"
    end
    local format = self:_document_format(doc)
    local by_extension = type(doc.file) == "string"
        and doc.file:lower():match("%.epub$") ~= nil
    if format then
        if format == "epub" then return true end
        return false, "当前文档不是 EPUB（" .. format .. "）"
    end
    if by_extension then return true end
    return false, "无法确认当前文档为 EPUB"
end

function ProgressService:is_supported()
    local doc, err = self:_document()
    if not doc then return false, err and err.message end
    return self:_is_supported(doc)
end

function ProgressService:_title(doc)
    local props = self.reader_ui.doc_props
    if type(props) == "table" then
        local title = clean_title(props.display_title) or clean_title(props.title)
        if title then return title end
    end
    local ok, doc_props = pcall(function() return doc:getDocumentProps() end)
    if ok and type(doc_props) == "table" then
        local title = clean_title(doc_props.title)
        if title then return title end
    end
    local _, name = util.splitFilePathName(doc.file)
    return clean_title(name)
end

function ProgressService:_partial_md5()
    local doc_settings = self.reader_ui.doc_settings
    if not doc_settings or type(doc_settings.readSetting) ~= "function" then
        return nil
    end
    local ok, value = pcall(function()
        return doc_settings:readSetting("partial_md5_checksum")
    end)
    if ok and type(value) == "string" then
        value = value:lower()
        if #value == 32 and value:match("^[0-9a-f]+$") then return value end
    end
    return nil
end

-- Snapshot of the current book. This is deliberately not a content identity:
-- Stage B adds the full SHA-256 book id.
function ProgressService:_book_snapshot()
    local doc, doc_err = self:_document()
    if not doc then return nil, doc_err end
    local supported, reason = self:_is_supported(doc)
    if not supported then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT, reason)
    end
    local file = doc.file
    if type(file) ~= "string" or file == "" then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT, "无法获取当前书籍路径")
    end
    local attr = lfs.attributes(file)
    if not attr or attr.mode ~= "file" then
        return nil, Errors.new(Errors.CODES.IO, "无法读取当前书籍文件")
    end
    local _, name = util.splitFilePathName(file)
    return {
        file_path = file,
        file_name = name,
        title = self:_title(doc),
        format = "epub",
        size = attr.size,
        mtime = attr.modification,
        partial_md5 = self:_partial_md5(),
    }
end

function ProgressService:_page_of(xpointer)
    local doc = self.reader_ui and self.reader_ui.document
    if not doc then return nil end
    local ok, page = pcall(doc.getPageFromXPointer, doc, xpointer)
    if ok and type(page) == "number" and page == math.floor(page)
        and page > 0 and page ~= math.huge then
        return page
    end
    return nil
end

function ProgressService:_engine_xpointer()
    local doc = self.reader_ui and self.reader_ui.document
    if not doc then return nil end
    local ok, xpointer = pcall(doc.getXPointer, doc)
    if ok and type(xpointer) == "string" and xpointer ~= "" then
        return xpointer
    end
    return nil
end

-- Page equality is the documented equivalent-location check for page mode.
-- In scroll mode it is weaker, and the returned match kind still says "page".
function ProgressService:_match_location(actual, target, target_page)
    if actual == target then return true, "exact" end
    local actual_page = self:_page_of(actual)
    if actual_page and target_page and actual_page == target_page then
        return true, "page"
    end
    return false
end

function ProgressService:_iso_now()
    return ProgressRecord.iso_timestamp(self.os_time())
end

-- The document can be closed or replaced while a jump is being verified.
-- Every check re-validates the book context instead of applying the result to
-- whatever document happens to be open at that moment (spec 2.2).
function ProgressService:_still_same_book(book)
    local doc = self.reader_ui and self.reader_ui.document
    if not doc or doc.file ~= book.file_path then return false end
    local attr = lfs.attributes(book.file_path)
    return attr ~= nil and attr.size == book.size
end

function ProgressService:_navigate(target_xpointer, expected_book, completion)
    local target_page = self:_page_of(target_xpointer)
    if not target_page then
        completion(Errors.new(Errors.CODES.INVALID_INPUT,
            "目标位置无法被当前阅读器解析"))
        return
    end
    if expected_book and not self:_still_same_book(expected_book) then
        completion(Errors.new(Errors.CODES.CANCELLED,
            "书籍已关闭或被替换，未执行跳转"))
        return
    end

    local deadline = self.now_ms() + self.timeout_ms
    local attempts = 0
    local finished = false
    local function finish(err, info)
        if finished then return end
        finished = true
        completion(err, info)
    end

    local function check()
        attempts = attempts + 1
        if expected_book and not self:_still_same_book(expected_book) then
            finish(Errors.new(Errors.CODES.CANCELLED,
                "书籍已关闭或被替换，已停止校验"), { attempts = attempts })
            return
        end
        local actual = self:_engine_xpointer()
        if actual then
            local matched, match_kind = self:_match_location(actual, target_xpointer, target_page)
            if matched then
                finish(nil, {
                    attempts = attempts,
                    match = match_kind,
                    actual = actual,
                    page = target_page,
                })
                return
            end
        end
        if self.now_ms() >= deadline then
            finish(Errors.new(Errors.CODES.UNCERTAIN,
                "跳转后无法确认已到达目标位置",
                { retryable = true, outcome = "uncertain",
                  detail = { attempts = attempts, target = target_xpointer } }),
                { attempts = attempts, actual = actual, page = target_page })
            return
        end
        self.schedule(self.poll_ms, check)
    end

    local event = self.event
    if not event then
        local ok, module = pcall(require, "ui/event")
        event = ok and module or nil
    end
    if not event or type(event.new) ~= "function" then
        finish(Errors.new(Errors.CODES.UNSUPPORTED, "缺少 KOReader 事件模块"))
        return
    end

    local ok, jump_err = pcall(function()
        self.reader_ui:handleEvent(event:new("GotoXPointer", target_xpointer))
    end)
    if not ok then
        finish(Errors.new(Errors.CODES.UNCERTAIN,
            "跳转请求失败: " .. tostring(jump_err),
            { outcome = "uncertain", retryable = true }))
        return
    end

    check()
end

function ProgressService:_check_context(context)
    local book, book_err = self:_book_snapshot()
    if not book then return nil, book_err end
    if context.book.file_path ~= book.file_path
        or context.book.size ~= book.size then
        return nil, Errors.new(Errors.CODES.CONFLICT,
            "当前打开的书籍与记录不一致，请打开对应书籍后重试")
    end
    return true
end

--- Reads the current position of the opened EPUB.
-- @treturn table|nil {book=..., progress={type="xpointer", value=..., percent?}, page=...}
function ProgressService:capture()
    local book, book_err = self:_book_snapshot()
    if not book then return nil, book_err end
    local rolling = self.reader_ui.rolling
    if not rolling or type(rolling.getLastProgress) ~= "function" then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT,
            "当前阅读器不支持读取 XPointer")
    end
    local ok, xpointer = pcall(function() return rolling:getLastProgress() end)
    if not ok or type(xpointer) ~= "string" or xpointer == "" then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT, "无法读取当前阅读位置")
    end
    local valid, pos_err = ProgressRecord.validate_position(
        { type = "xpointer", value = xpointer })
    if not valid then return nil, pos_err end
    local page = self:_page_of(xpointer)
    if not page then
        return nil, Errors.new(Errors.CODES.INVALID_INPUT,
            "当前阅读位置无法被引擎解析")
    end

    local percent
    if type(rolling.getLastPercent) == "function" then
        local ok_pct, value = pcall(function() return rolling:getLastPercent() end)
        if ok_pct then percent = sanitize_percent(value) end
    end

    return {
        book = book,
        progress = {
            type = "xpointer",
            value = xpointer,
            percent = percent,
        },
        page = page,
    }
end

--- Navigates to `position` and verifies the result.
-- On failure the original position is restored when possible. The restore
-- point is persisted before the jump, and `completion` is called exactly once.
-- @tparam table context context returned by capture()
-- @tparam table position {type="xpointer", value=..., percent?}
-- @tparam function completion completion(err, result)
function ProgressService:apply(context, position, completion)
    completion = completion or function() end
    local finished = false
    local function finish(err, result)
        if finished then return end
        finished = true
        completion(err, result)
    end

    if type(context) ~= "table" or type(context.book) ~= "table"
        or type(context.progress) ~= "table" then
        return finish(Errors.new(Errors.CODES.INVALID_INPUT, "书籍上下文无效"))
    end
    local valid, pos_err = ProgressRecord.validate_position(position)
    if not valid then return finish(pos_err) end
    if not self:_page_of(position.value) then
        return finish(Errors.new(Errors.CODES.INVALID_INPUT,
            "导入的位置无法被当前阅读器解析"))
    end
    local context_ok, context_err = self:_check_context(context)
    if not context_ok then return finish(context_err) end

    local before, capture_err = self:capture()
    if not before then return finish(capture_err) end

    if before.progress.value == position.value then
        return finish(nil, {
            no_navigation = true,
            position = position,
            page = before.page,
        })
    end

    local restore_point = {
        book = before.book,
        position = before.progress,
        created_at = self:_iso_now(),
        source = "apply_import",
    }
    local saved, save_err = self.store:save_restore_point(restore_point)
    if not saved then
        -- Never navigate without a persisted restore point.
        return finish(save_err)
    end

    self:_navigate(position.value, before.book, function(nav_err, nav_info)
        if not nav_err then
            return finish(nil, {
                position = position,
                page = nav_info and nav_info.page,
                match = nav_info and nav_info.match,
                attempts = nav_info and nav_info.attempts,
                restore_point = restore_point,
            })
        end
        if nav_err.code == Errors.CODES.CANCELLED then
            -- The document is gone; there is no meaningful rollback target.
            return finish(nav_err)
        end

        self:_navigate(before.progress.value, before.book, function(rollback_err, rollback_info)
            if rollback_err then
                return finish(Errors.new(Errors.CODES.UNCERTAIN,
                    nav_err.message .. "；尝试恢复原位置也未得到确认",
                    { retryable = true, outcome = "uncertain",
                      detail = { navigation = nav_err, rollback = rollback_err } }),
                    { rollback = false, rollback_info = rollback_info })
            end
            -- The jump was not verified and the original position is restored;
            -- there is nothing for "undo" to do.
            self.store:clear_restore_point()
            finish(nav_err, { rollback = true, rollback_position = before.progress })
        end)
    end)
end

--- Restores the position saved before the last successful apply.
-- @tparam function completion completion(err, result)
function ProgressService:undo(completion)
    completion = completion or function() end
    local finished = false
    local function finish(err, result)
        if finished then return end
        finished = true
        completion(err, result)
    end

    local restore_point, rp_err = self.store:get_restore_point()
    if rp_err then return finish(rp_err) end
    if not restore_point then
        return finish(Errors.new(Errors.CODES.NOT_FOUND, "没有可撤销的进度恢复点"))
    end

    local before, capture_err = self:capture()
    if not before then return finish(capture_err) end

    if restore_point.book.file_path ~= before.book.file_path
        or restore_point.book.size ~= before.book.size then
        return finish(Errors.new(Errors.CODES.CONFLICT,
            "恢复点属于另一本书或另一份内容，请打开对应书籍后重试"))
    end

    if before.progress.value == restore_point.position.value then
        local cleared, clear_err = self.store:clear_restore_point()
        if not cleared then return finish(clear_err) end
        return finish(nil, { no_navigation = true, position = before.progress })
    end

    self:_navigate(restore_point.position.value, before.book, function(nav_err, nav_info)
        if nav_err then
            if nav_err.code == Errors.CODES.CANCELLED then
                return finish(nav_err)
            end
            self:_navigate(before.progress.value, before.book, function(rollback_err)
                if rollback_err then
                    return finish(Errors.new(Errors.CODES.UNCERTAIN,
                        nav_err.message .. "；撤销后回退也未得到确认",
                        { retryable = true, outcome = "uncertain",
                          detail = { navigation = nav_err, rollback = rollback_err } }))
                end
                finish(nav_err, { rollback = true })
            end)
            return
        end
        local cleared, clear_err = self.store:clear_restore_point()
        finish(nil, {
            position = restore_point.position,
            page = nav_info and nav_info.page,
            match = nav_info and nav_info.match,
            attempts = nav_info and nav_info.attempts,
            cleared = cleared and true or false,
            warning = cleared and nil or clear_err,
        })
    end)
end

function ProgressService:has_restore_point()
    local restore_point = self.store:get_restore_point()
    return restore_point ~= nil
end

return ProgressService
