--[[--
Integration check for Stage A against the real crengine engine and a real
ReaderUI, using KOReader's own juliet.epub fixture. This is the macOS-side
evidence for "export → turn pages → import → restore" ; it is not a substitute
for the manual UI / Kindle / Kobo acceptance required by the spec.
]]

describe("Stage A integration with ReaderUI", function()
    local DocumentRegistry, Event, LocalStore, ProgressService, ProgressRecord
    local ExportStore, ReaderUI, Screen
    local lfs

    local readerui, service, store, export_store
    local tmp_root
    local queue, now = {}, 0

    local function schedule(_, callback)
        queue[#queue + 1] = callback
    end

    local function flush_scheduled(limit)
        local count = 0
        while #queue > 0 and count < (limit or 50) do
            count = count + 1
            now = now + 100
            local callback = table.remove(queue, 1)
            callback()
        end
        return count
    end

    local function call_async(fn)
        local captured = { count = 0 }
        fn(function(err, result)
            captured.count = captured.count + 1
            captured.err = err
            captured.result = result
        end)
        flush_scheduled()
        return captured
    end

    local function make_dir()
        local path = os.tmpname()
        os.remove(path)
        assert(lfs.mkdir(path))
        return path
    end

    setup(function()
        require("commonrequire")
        lfs = require("libs/libkoreader-lfs")
        DocumentRegistry = require("document/documentregistry")
        Event = require("ui/event")
        ReaderUI = require("apps/reader/readerui")
        Screen = require("device").screen
        LocalStore = require("modules.storage")
        ProgressRecord = require("modules.progress_record")
        ProgressService = require("modules.progress")
        ExportStore = require("modules.export_store")

        local koreader_dir = os.getenv("BPS_KOREADER_DIR") or "../../koreader"
        local epub = koreader_dir .. "/test/juliet.epub"
        if not lfs.attributes(epub) then
            pending("juliet.epub fixture not found at " .. epub)
            return
        end

        disable_plugins()
        tmp_root = make_dir()
        store = LocalStore:new{ dir = tmp_root .. "/state" }
        export_store = ExportStore:new{ dir = tmp_root .. "/exports" }
        readerui = ReaderUI:new{
            dimen = Screen:getSize(),
            document = DocumentRegistry:openDocument(epub),
        }
        service = ProgressService:new{
            reader_ui = readerui,
            store = store,
            event = Event,
            schedule = schedule,
            now_ms = function() return now end,
            timeout_ms = 1000,
            poll_ms = 100,
        }
    end)

    teardown(function()
        if readerui then
            readerui:onClose()
            readerui = nil
        end
        if tmp_root then
            local function rm_rf(path)
                local attr = lfs.attributes(path)
                if not attr then return end
                if attr.mode == "directory" then
                    for entry in lfs.dir(path) do
                        if entry ~= "." and entry ~= ".." then rm_rf(path .. "/" .. entry) end
                    end
                    lfs.rmdir(path)
                else
                    os.remove(path)
                end
            end
            rm_rf(tmp_root)
        end
    end)

    it("captures the real engine position of the opened EPUB", function()
        readerui.rolling:onGotoPage(12)
        local context, err = service:capture()
        assert.is_nil(err)
        assert.is_truthy(#context.progress.value > 0)
        assert.is_equal(12, context.page)
        assert.is_equal("epub", context.book.format)
        assert.is_truthy(context.book.size > 0)
    end)

    it("exports, turns pages, imports and restores the position", function()
        readerui.rolling:onGotoPage(12)
        local context = assert(service:capture())
        local record = assert(ProgressRecord.from_capture(context))
        local path = assert(export_store:save(record, { filename = "integration.json" }))
        assert.is_truthy(lfs.attributes(path))

        local entries = assert(export_store:list())
        assert.is_equal(1, #entries)
        assert.is_true(entries[1].valid)
        local loaded = assert(export_store:load(path))
        local matched, mismatch = ProgressRecord.matches_book(loaded, context.book)
        assert.is_true(matched, mismatch)

        readerui.rolling:onGotoPage(3)
        local captured = call_async(function(done)
            service:apply(context, loaded.progress, done)
        end)
        assert.is_nil(captured.err)
        assert.is_equal(1, captured.count)
        assert.is_equal(12, readerui.rolling.current_page)
        assert.is_equal(12, readerui.document:getPageFromXPointer(readerui.document:getXPointer()))
        assert.is_truthy(store:get_restore_point())

        -- undo must return to the position that was active when importing
        local undone = call_async(function(done) service:undo(done) end)
        assert.is_nil(undone.err)
        assert.is_equal(3, readerui.rolling.current_page)
        assert.is_nil(store:get_restore_point())
    end)

    it("refuses a record from a different book", function()
        readerui.rolling:onGotoPage(5)
        local context = assert(service:capture())
        local record = assert(ProgressRecord.from_capture(context))
        local other = {
            size = context.book.size + 1,
            file_name = "another.epub",
            title = "另一本书",
        }
        local ok = ProgressRecord.matches_book(record, other)
        assert.is_false(ok)
    end)
end)
