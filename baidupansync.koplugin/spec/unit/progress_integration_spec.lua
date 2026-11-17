--[[--
Stage B integration: full SHA-256 identity + manual JSON exchange.

Uses the real crengine engine and KOReader's ReaderUI with juliet.epub. Two
independent "devices" (separate settings directories, device ids, baselines and
export directories) exchange one exported record through the file system.

This is the macOS-side automated evidence for the Stage B acceptance
"two devices exchange JSON and restore the same EPUB; wrong book and bad JSON
are rejected". Real-device testing is still required.
]]

describe("Stage B integration: two-device JSON exchange", function()
    local BookIdentity, ConfigStore, Event, ExportStore, Hash, LocalStore
    local ProgressRecord, ProgressService, ReaderUI, Screen, SyncEngine, SyncState
    local DocumentRegistry, FileUtil, lfs

    local readerui, service, store
    local device_a, device_b, tmp_root
    local queue, now = {}, 0

    local function schedule_hash(callback) callback() end

    local function flush_position_checks(limit)
        local count = 0
        while #queue > 0 and count < (limit or 20) do
            count = count + 1
            now = now + 100
            local callback = table.remove(queue, 1)
            callback()
        end
        return count
    end

    local function call_export(engine, context)
        local captured = { count = 0 }
        engine:export_current(context, {
            schedule = schedule_hash,
            is_cancelled = function() return false end,
        }, function(err, result)
            captured.count = captured.count + 1
            captured.err = err
            captured.result = result
        end)
        flush_position_checks()
        return captured
    end

    local function call_import(engine, path, context)
        local captured = { count = 0 }
        engine:import_from_file(path, context, {
            schedule = schedule_hash,
            is_cancelled = function() return false end,
            confirm = function(info, decide)
                captured.info = info
                decide(true)
            end,
        }, function(err, result)
            captured.count = captured.count + 1
            captured.err = err
            captured.result = result
        end)
        flush_position_checks()
        return captured
    end

    local function make_device(label)
        local dir = string.format("%s/%s", tmp_root, label)
        assert(lfs.mkdir(dir))
        local config = ConfigStore:new{ dir = dir }
        local device_id = assert(config:ensure_device_id{ label = label })
        local exports = ExportStore:new{ dir = dir .. "/exports" }
        local state = SyncState:new{ dir = dir }
        local identity = BookIdentity:new{ dir = dir }
        local engine = SyncEngine:new{
            identity = identity,
            progress = service,
            exports = exports,
            state = state,
            config = config,
            device_label = label,
            now = function() return 1763300000 end,
        }
        return {
            dir = dir,
            config = config,
            device_id = device_id,
            exports = exports,
            state = state,
            identity = identity,
            engine = engine,
        }
    end

    local function copy_file(source, destination)
        local input = assert(io.open(source, "rb"))
        local data = input:read("*a")
        input:close()
        local output = assert(io.open(destination, "wb"))
        output:write(data)
        output:close()
        return destination
    end

    setup(function()
        require("commonrequire")
        lfs = require("libs/libkoreader-lfs")
        FileUtil = require("modules.file_util")
        BookIdentity = require("modules.book_identity")
        ConfigStore = require("modules.config_store")
        Event = require("ui/event")
        ExportStore = require("modules.export_store")
        Hash = require("modules.hash")
        LocalStore = require("modules.storage")
        ProgressRecord = require("modules.progress_record")
        ProgressService = require("modules.progress")
        ReaderUI = require("apps/reader/readerui")
        Screen = require("device").screen
        SyncEngine = require("modules.sync_engine")
        SyncState = require("modules.sync_state")
        DocumentRegistry = require("document/documentregistry")

        local koreader_dir = os.getenv("BPS_KOREADER_DIR") or "../../koreader"
        local epub = koreader_dir .. "/test/juliet.epub"
        if not lfs.attributes(epub) then
            pending("juliet.epub fixture not found at " .. epub)
            return
        end

        disable_plugins()
        tmp_root = os.tmpname()
        os.remove(tmp_root)
        assert(lfs.mkdir(tmp_root))

        store = LocalStore:new{ dir = tmp_root .. "/device-a/state" }
        readerui = ReaderUI:new{
            dimen = Screen:getSize(),
            document = DocumentRegistry:openDocument(epub),
        }
        local undo_identity = BookIdentity:new{ dir = tmp_root .. "/undo-identity" }
        service = ProgressService:new{
            identity = { identify = function(_, path, opts, done)
                opts.schedule = function(fn) queue[#queue + 1] = fn end
                undo_identity:identify(path, opts, done)
            end },
            reader_ui = readerui,
            store = store,
            event = Event,
            schedule = function(_, callback) queue[#queue + 1] = callback end,
            now_ms = function() return now end,
            timeout_ms = 1000,
            poll_ms = 100,
        }
        device_a = make_device("device-a")
        device_b = make_device("device-b")
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

    it("exports a cloud record with full identity and a unique writeId", function()
        readerui.rolling:onGotoPage(12)
        local context = assert(service:capture())
        local exported = call_export(device_a.engine, context)
        assert.is_nil(exported.err)
        assert.is_equal(1, exported.count)
        local record = exported.result.record
        assert.is_true(Hash.is_sha256_hex(record.book.contentSha256))
        assert.is_equal(record.book.contentSha256, record.book.id)
        assert.is_equal(12, context.page)
        assert.is_true(#record.sync.writeId >= 16)
        assert.is_truthy(record.sync.deviceId:match("^device%-a%-"))
        assert.is_true(record.sync.revision >= 1)
        assert.is_truthy(lfs.attributes(exported.result.path))
    end)

    it("restores the exported record on a second device", function()
        readerui.rolling:onGotoPage(12)
        local context = assert(service:capture())
        local exported = call_export(device_a.engine, context)
        assert.is_nil(exported.err)

        -- Simulate a USB/cloud transfer: the second device has its own settings,
        -- device id, baseline and export directory.
        FileUtil.mkdir_p(device_b.exports:get_dir())
        local transferred = device_b.exports:get_dir() .. "/from-a.json"
        copy_file(exported.result.path, transferred)

        readerui.rolling:onGotoPage(3)
        local b_context = assert(service:capture())
        local imported = call_import(device_b.engine, transferred, b_context)
        assert.is_nil(imported.err)
        assert.is_equal(1, imported.count)
        assert.is_equal("first_contact", imported.info.classification.kind)
        assert.is_equal(12, readerui.rolling.current_page)
        assert.is_equal(12, readerui.document:getPageFromXPointer(readerui.document:getXPointer()))

        local baseline = assert(device_b.state:get(
            SyncEngine.MANUAL_BACKEND_ID, imported.result.record.book.id))
        assert.is_equal("present", baseline.remote_state)
        assert.is_equal(imported.result.record.sync.revision, baseline.base_revision)
        assert.is_equal(imported.result.fingerprint, baseline.base_remote_fingerprint)
        assert.is_equal(imported.result.record.sync.writeId, baseline.last_write_id)
        assert.is_equal(device_b.device_id,
            assert(device_b.config:get_device_id()))
        assert.is_true(device_a.device_id ~= device_b.device_id)

        local undone = { count = 0 }
        service:undo(function(err)
            undone.count = undone.count + 1
            undone.err = err
        end)
        flush_position_checks()
        assert.is_nil(undone.err)
        assert.is_equal(1, undone.count)
        assert.is_equal(3, readerui.rolling.current_page)
    end)

    it("rejects a record whose full-content identity differs", function()
        readerui.rolling:onGotoPage(5)
        local context = assert(service:capture())
        local exported = call_export(device_a.engine, context)
        assert.is_nil(exported.err)

        -- Change both id and contentSha256 consistently: schema-valid, wrong book.
        local changed = ProgressRecord.decode(exported.result.raw)
        local other = string.rep("f", 64)
        changed.book.id = other
        changed.book.contentSha256 = other
        local text = assert(ProgressRecord.encode(changed))
        FileUtil.mkdir_p(device_b.exports:get_dir())
        local path = device_b.exports:get_dir() .. "/wrong-book.json"
        local file = assert(io.open(path, "wb"))
        file:write(text)
        file:close()

        local imported = call_import(device_b.engine, path, context)
        assert.is_nil(imported.result)
        assert.is_equal("CONFLICT", imported.err.code)
        assert.is_equal(5, readerui.rolling.current_page)
    end)

    it("rejects malformed JSON before touching the reader position", function()
        readerui.rolling:onGotoPage(4)
        local context = assert(service:capture())
        FileUtil.mkdir_p(device_b.exports:get_dir())
        local path = device_b.exports:get_dir() .. "/bad.json"
        local file = assert(io.open(path, "wb"))
        file:write("{not json")
        file:close()

        local imported = call_import(device_b.engine, path, context)
        assert.is_nil(imported.result)
        assert.is_equal("INVALID_INPUT", imported.err.code)
        assert.is_equal(4, readerui.rolling.current_page)
    end)

    it("classifies a changed record as remote_changed on re-import", function()
        readerui.rolling:onGotoPage(8)
        local context = assert(service:capture())
        local first = call_export(device_a.engine, context)
        assert.is_nil(first.err)

        readerui.rolling:onGotoPage(9)
        local second_context = assert(service:capture())
        local second = call_export(device_a.engine, second_context)
        assert.is_nil(second.err)
        assert.is_equal(first.result.record.sync.revision + 1,
            second.result.record.sync.revision)

        FileUtil.mkdir_p(device_b.exports:get_dir())
        local transferred = device_b.exports:get_dir() .. "/from-a-2.json"
        copy_file(second.result.path, transferred)

        readerui.rolling:onGotoPage(4)
        local b_context = assert(service:capture())
        local imported = call_import(device_b.engine, transferred, b_context)
        assert.is_nil(imported.err)
        assert.is_equal("remote_changed", imported.info.classification.kind)
        assert.is_true(imported.info.classification.requires_confirmation)
        assert.is_equal(9, readerui.rolling.current_page)
    end)
    it("applies cloud progress through the real crengine and keeps undo working", function()
        local backend=require("spec/fixtures/fake_backend"):new()
        local endpoint=os.getenv("BPS_DAV_TEST_URL")
        if endpoint then
            local DAV=require("modules/webdav")
            local transport=function(req,done)done(require("modules/dav_transport").perform(req))end
            local base=assert(DAV:new{root_url=endpoint,username="u",password="p",transport=transport})
            local namespace="reader-test-"..assert(require("modules/random").hex(16))
            base:mkdir(namespace,function(e)assert.is_nil(e)end)
            backend=assert(DAV:new{root_url=endpoint..namespace.."/",username="u",password="p",transport=transport})
        end
        local cloud=require("modules/cloud_service"):new{backend=backend,identity=device_a.identity,
            progress=service,state=device_a.state,config=device_a.config,temp_dir=tmp_root.."/cloud-temp"}
        local opts={schedule=schedule_hash,confirm=function(_,done)done(true)end}
        readerui.rolling:onGotoPage(12)
        local initial=assert(service:capture())
        local book_uploaded
        cloud:upload_book(initial,opts,function(e,r)assert.is_nil(e);book_uploaded=r end)
        flush_position_checks()
        assert.is_truthy(book_uploaded)
        local library
        cloud:list(opts,function(e,r)assert.is_nil(e);library=r end)
        assert.is_equal(1,#library.entries)
        opts.home_dir=tmp_root.."/cloud-downloads"
        assert(lfs.mkdir(opts.home_dir))
        local downloaded
        cloud:download_book(library.entries[1],opts,function(e,r)assert.is_nil(e);downloaded=r end)
        flush_position_checks()
        assert.is_truthy(downloaded)
        local downloaded_identity
        device_a.identity:identify(downloaded.path,{use_cache=false,schedule=schedule_hash},function(e,r)
            assert.is_nil(e);downloaded_identity=r
        end)
        assert.is_equal(book_uploaded.record.bookId,downloaded_identity.book_id)
        local uploaded
        cloud:progress_operation("upload",initial,opts,function(e,r)assert.is_nil(e);uploaded=r end)
        flush_position_checks()
        assert.is_truthy(uploaded)
        readerui.rolling:onGotoPage(3)
        local applied
        cloud:progress_operation("download",assert(service:capture()),opts,function(e,r)assert.is_nil(e);applied=r end)
        flush_position_checks()
        assert.is_truthy(applied)
        assert.is_equal(12,readerui.document:getPageFromXPointer(readerui.document:getXPointer()))
        local restore=assert(store:get_restore_point())
        assert.is_equal(backend.backend_id,restore.book.source_backend_id)
        local undone=false
        service:undo(function(e)assert.is_nil(e);undone=true end)
        flush_position_checks()
        assert.is_true(undone)
        assert.is_equal(3,readerui.document:getPageFromXPointer(readerui.document:getXPointer()))
    end)

end)
