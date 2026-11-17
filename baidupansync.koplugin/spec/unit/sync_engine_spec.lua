describe("sync_engine (Stage B local exchange)", function()
    local BookIdentity, ConfigStore, ExportStore, FileUtil, ProgressRecord
    local SyncEngine, SyncState, lfs, json

    local tmp_root, book_path, book_size, book_content
    local identity, exports, state, config, progress

    local function write_book(name, content)
        local path = tmp_root .. "/" .. name
        local file = assert(io.open(path, "wb"))
        file:write(content)
        file:close()
        return path
    end

    local function context()
        return {
            book = {
                file_path = book_path,
                file_name = "book.epub",
                title = "测试书籍",
                format = "epub",
                size = book_size,
            },
            progress = {
                type = "xpointer",
                value = "/body/DocFragment[1]/body/div/p[3]/text().5",
                percent = 0.3,
            },
            page = 3,
        }
    end

    local function new_engine(overrides)
        overrides = overrides or {}
        return SyncEngine:new{
            identity = overrides.identity or identity,
            progress = overrides.progress or progress,
            exports = overrides.exports or exports,
            state = overrides.state or state,
            config = overrides.config or config,
            device_label = "spec-device",
            now = function() return 1763300000 end,
        }
    end

    local function run(fn)
        local captured = { count = 0 }
        fn(function(err, result)
            captured.count = captured.count + 1
            captured.err = err
            captured.result = result
        end)
        return captured
    end

    local function export_opts(extra)
        local opts = {
            schedule = function(callback) callback() end,
            is_cancelled = function() return false end,
        }
        for key, value in pairs(extra or {}) do opts[key] = value end
        return opts
    end

    local function import_opts(extra)
        local opts = export_opts(extra)
        opts.confirm = opts.confirm or function(info, decide)
            opts.last_info = info
            decide(true)
        end
        return opts
    end

    setup(function()
        require("commonrequire")
        lfs = require("libs/libkoreader-lfs")
        json = require("json")
        BookIdentity = require("modules.book_identity")
        ConfigStore = require("modules.config_store")
        ExportStore = require("modules.export_store")
        FileUtil = require("modules.file_util")
        ProgressRecord = require("modules.progress_record")
        SyncEngine = require("modules.sync_engine")
        SyncState = require("modules.sync_state")

        tmp_root = os.tmpname()
        os.remove(tmp_root)
        assert(lfs.mkdir(tmp_root))
        book_content = string.rep("epub-bytes-", 100)
        book_path = write_book("book.epub", book_content)
        book_size = lfs.attributes(book_path, "size")

        identity = BookIdentity:new{ dir = tmp_root .. "/identity" }
        exports = ExportStore:new{ dir = tmp_root .. "/exports" }
        state = SyncState:new{ dir = tmp_root .. "/state" }
        config = ConfigStore:new{ dir = tmp_root .. "/config" }
        progress = {
            calls = 0,
            apply = function(self, _, position, completion, opts)
                self.calls = self.calls + 1
                if opts and opts.on_state then
                    opts.on_state("persisting_restore")
                    opts.on_state("applying")
                    opts.on_state("checking_position")
                end
                completion(nil, { position = position })
            end,
        }
    end)

    before_each(function()
        progress.calls = 0
    end)

    teardown(function()
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
    end)

    it("exports a valid cloud record, verifies it and commits a baseline", function()
        local engine = new_engine()
        local hash_starts, hash_finishes = 0, 0
        local exported = run(function(done)
            engine:export_current(context(), export_opts{
                on_hash_start = function() hash_starts = hash_starts + 1 end,
                on_hash_finish = function() hash_finishes = hash_finishes + 1 end,
            }, done)
        end)
        assert.is_nil(exported.err)
        assert.is_equal(1, exported.count)
        local result = exported.result
        assert.is_equal(1, result.revision)
        assert.is_true(result.record.book.id == result.identity.content_sha256)
        assert.is_equal(book_size, result.record.book.size)
        assert.is_equal(0.3, result.record.progress.percent)
        assert.is_truthy(lfs.attributes(result.path))
        assert.is_equal(1, hash_starts)
        assert.is_equal(1, hash_finishes)

        local baseline = assert(state:get(SyncEngine.MANUAL_BACKEND_ID, result.record.book.id))
        assert.is_equal(result.fingerprint, baseline.base_remote_fingerprint)
        assert.is_equal(1, baseline.base_revision)
        assert.is_equal(result.record.sync.writeId, baseline.last_write_id)

        local states = {}
        for _, item in ipairs(result.task.history) do states[#states + 1] = item.state end
        assert.is_equal("preparing", states[2])
        assert.is_equal("done", states[#states])
    end)

    it("uses the identity cache and increments the revision", function()
        local engine = new_engine()
        local first = run(function(done) engine:export_current(context(), export_opts(), done) end)
        assert.is_nil(first.err)

        local starts = 0
        local second = run(function(done)
            engine:export_current(context(), export_opts{
                on_hash_start = function() starts = starts + 1 end,
            }, done)
        end)
        assert.is_nil(second.err)
        assert.is_equal(0, starts)
        assert.is_true(second.result.identity.cached)
        assert.is_equal(first.result.revision + 1, second.result.revision)
        assert.is_true(first.result.record.sync.writeId ~= second.result.record.sync.writeId)
        assert.is_true(first.result.fingerprint ~= second.result.fingerprint)
    end)

    it("cancels export when hashing is cancelled", function()
        -- A fresh identity cache forces a real hash so cancellation can be observed.
        local engine = new_engine{
            identity = BookIdentity:new{ dir = tmp_root .. "/identity-cancel" },
        }
        local exported = run(function(done)
            engine:export_current(context(), export_opts{
                is_cancelled = function() return true end,
            }, done)
        end)
        assert.is_nil(exported.result)
        assert.is_equal("CANCELLED", exported.err.code)
        assert.is_equal(0, progress.calls)
    end)

    it("imports on a second device and updates its own baseline", function()
        local engine_a = new_engine()
        local exported = run(function(done) engine_a:export_current(context(), export_opts(), done) end)
        assert.is_nil(exported.err)

        local device_b_dir = tmp_root .. "/device-b"
        assert(lfs.mkdir(device_b_dir))
        local exports_b = ExportStore:new{ dir = device_b_dir .. "/exports" }
        assert(FileUtil.mkdir_p(exports_b:get_dir()))
        local path_b = exports_b:get_dir() .. "/from-a.json"
        local raw = assert(exports:read(exported.result.path))
        local out = assert(io.open(path_b, "wb"))
        out:write(raw)
        out:close()

        local engine_b = new_engine{
            identity = BookIdentity:new{ dir = device_b_dir },
            config = ConfigStore:new{ dir = device_b_dir },
            state = SyncState:new{ dir = device_b_dir },
            exports = exports_b,
        }
        local imported = run(function(done)
            engine_b:import_from_file(path_b, context(), import_opts(), done)
        end)
        assert.is_nil(imported.err)
        assert.is_equal(1, progress.calls)
        assert.is_equal("first_contact", imported.result.classification.kind)
        local baseline = assert(engine_b.state:get(
            SyncEngine.MANUAL_BACKEND_ID, imported.result.record.book.id))
        assert.is_equal(imported.result.fingerprint, baseline.base_remote_fingerprint)
    end)

    it("accepts the same bytes at a different path", function()
        local engine = new_engine()
        local exported = run(function(done) engine:export_current(context(), export_opts(), done) end)
        assert.is_nil(exported.err)

        local copy_path = write_book("copy.epub", book_content)
        local copy_context = context()
        copy_context.book.file_path = copy_path
        copy_context.book.file_name = "copy.epub"

        local imported = run(function(done)
            engine:import_from_file(exported.result.path, copy_context, import_opts(), done)
        end)
        assert.is_nil(imported.err)
        assert.is_equal(1, progress.calls)
        assert.is_equal(exported.result.record.book.id,
            imported.result.record.book.id)
    end)

    it("rejects a schema-valid record for a different book before applying", function()
        local engine = new_engine()
        local exported = run(function(done) engine:export_current(context(), export_opts(), done) end)
        assert.is_nil(exported.err)

        local changed = ProgressRecord.decode(exported.result.raw)
        local other = string.rep("f", 64)
        changed.book.id = other
        changed.book.contentSha256 = other
        local text = assert(ProgressRecord.encode(changed))
        local path = exports:get_dir() .. "/wrong.json"
        local file = assert(io.open(path, "wb"))
        file:write(text)
        file:close()

        local calls_before = progress.calls
        local imported = run(function(done)
            engine:import_from_file(path, context(), import_opts(), done)
        end)
        assert.is_nil(imported.result)
        assert.is_equal("CONFLICT", imported.err.code)
        assert.is_equal(calls_before, progress.calls)
    end)

    it("rejects malformed JSON", function()
        local path = exports:get_dir() .. "/bad.json"
        local file = assert(io.open(path, "wb"))
        file:write("{not json")
        file:close()
        local engine = new_engine()
        local imported = run(function(done)
            engine:import_from_file(path, context(), import_opts(), done)
        end)
        assert.is_nil(imported.result)
        assert.is_equal("INVALID_INPUT", imported.err.code)
    end)

    it("cancels when the user declines the confirmation", function()
        local engine = new_engine()
        local exported = run(function(done) engine:export_current(context(), export_opts(), done) end)
        assert.is_nil(exported.err)

        local imported = run(function(done)
            engine:import_from_file(exported.result.path, context(), import_opts{
                confirm = function(_, decide) decide(false) end,
            }, done)
        end)
        assert.is_nil(imported.result)
        assert.is_equal("CANCELLED", imported.err.code)
        assert.is_equal(0, progress.calls)
    end)

    it("classifies a changed record without a revision bump", function()
        local engine = new_engine()
        local exported = run(function(done) engine:export_current(context(), export_opts(), done) end)
        assert.is_nil(exported.err)

        -- First association.
        run(function(done)
            engine:import_from_file(exported.result.path, context(), import_opts(), done)
        end)

        -- Same revision, different progress: a same-revision conflict.
        local changed = ProgressRecord.decode(exported.result.raw)
        changed.progress.value = "/body/DocFragment[1]/body/div/p[9]/text().1"
        local text = assert(ProgressRecord.encode(changed))
        local path = exports:get_dir() .. "/same-rev.json"
        local file = assert(io.open(path, "wb"))
        file:write(text)
        file:close()

        local opts = import_opts()
        local imported = run(function(done)
            engine:import_from_file(path, context(), opts, done)
        end)
        assert.is_nil(imported.err)
        assert.is_equal("same_revision_different_record",
            imported.result.classification.kind)
        assert.is_true(imported.result.classification.requires_confirmation)
        assert.is_equal("same_revision_different_record", opts.last_info.classification.kind)
    end)

    it("reports uncertain when the baseline cannot be committed after importing", function()
        local engine = new_engine()
        local exported = run(function(done) engine:export_current(context(), export_opts(), done) end)
        assert.is_nil(exported.err)

        local failing_state = {
            get = function() return nil end,
            put = function()
                return nil, { code = "IO", message = "disk full" }
            end,
        }
        local engine_fail = new_engine{ state = failing_state }
        local imported = run(function(done)
            engine_fail:import_from_file(exported.result.path, context(), import_opts(), done)
        end)
        assert.is_equal("uncertain", imported.err.outcome)
        assert.is_true(imported.result.applied)
        assert.is_false(imported.result.baseline_committed)
        assert.is_equal(1, progress.calls)
    end)

    it("reports uncertain when the export file cannot be committed to the baseline", function()
        local failing_state = {
            get = function() return nil end,
            put = function()
                return nil, { code = "IO", message = "disk full" }
            end,
        }
        local engine = new_engine{ state = failing_state }
        local exported = run(function(done)
            engine:export_current(context(), export_opts(), done)
        end)
        assert.is_equal("uncertain", exported.err.outcome)
        assert.is_truthy(exported.result.path)
        assert.is_false(exported.result.baseline_committed)
    end)
    it("stops export when reader context changes during scheduled hashing", function()
        identity:invalidate(book_path)
        local queue, invalid = {}, false
        local guarded = {
            _check_context = function()
                if invalid then return nil, require("modules/errors").new("CONFLICT", "changed") end
                return true
            end,
        }
        local engine = new_engine{ progress = guarded }
        local count, failure = 0
        engine:export_current(context(), {
            schedule = function(fn) queue[#queue+1] = fn end,
        }, function(e) count=count+1;failure=e end)
        invalid=true
        while #queue>0 do table.remove(queue,1)() end
        assert.is_equal(1,count)
        assert.is_equal("CONFLICT",failure.code)
    end)

    it("keeps one active task across identity access and releases it on completion", function()
        identity:invalidate(book_path)
        local engine=new_engine()
        assert.is_equal(SyncEngine.MANUAL_BACKEND_ID,engine:get_manual_backend_id())
        assert.is_equal(SyncEngine.MANUAL_BACKEND_ID,engine:get_manual_backend_id())
        local queue,first,second,third={}
        engine:export_current(context(),{schedule=function(fn)queue[#queue+1]=fn end},function(e,r)first={e=e,r=r}end)
        engine:export_current(context(),export_opts(),function(e)second=e end)
        assert.is_equal("CONFLICT",second.code)
        while #queue>0 do table.remove(queue,1)() end
        assert.is_nil(first.e);assert.is_truthy(first.r)
        engine:export_current(context(),export_opts(),function(e,r)third={e=e,r=r}end)
        assert.is_nil(third.e);assert.is_truthy(third.r)
    end)

end)
