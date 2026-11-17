describe("progress service (Stage A navigation)", function()
    local Event, LocalStore, ProgressService
    local FakeReader, Errors, lfs

    local tmp_root
    local book_index = 0
    local state_index = 0

    local function write_book(content)
        book_index = book_index + 1
        local path = string.format("%s/book-%d.epub", tmp_root, book_index)
        local file = assert(io.open(path, "wb"))
        file:write(content)
        file:close()
        return path
    end

    local function make_dir()
        local path = os.tmpname()
        os.remove(path)
        assert(lfs.mkdir(path))
        return path
    end

    local function new_clock()
        local queue, now = {}, 0
        return {
            schedule = function(_, callback) queue[#queue + 1] = callback end,
            now_ms = function() return now end,
            drain = function(_, max)
                local count = 0
                while #queue > 0 and count < (max or 2000) do
                    count = count + 1
                    now = now + 100
                    local callback = table.remove(queue, 1)
                    callback()
                end
                return count
            end,
        }
    end

    local function new_service(ui, store, clock)
        clock = clock or new_clock()
        if not store then
            state_index = state_index + 1
            store = LocalStore:new{ dir = string.format("%s/state-%d", tmp_root, state_index) }
        end
        local service = ProgressService:new{
            reader_ui = ui,
            store = store,
            event = Event,
            schedule = clock.schedule,
            now_ms = clock.now_ms,
            timeout_ms = 1000,
            poll_ms = 100,
        }
        return service, store, clock
    end

    local function run_completion(fn)
        local captured = { count = 0 }
        fn(function(err, result)
            captured.count = captured.count + 1
            captured.err = err
            captured.result = result
        end)
        return captured
    end

    setup(function()
        require("commonrequire")
        lfs = require("libs/libkoreader-lfs")
        Event = require("ui/event")
        LocalStore = require("modules.storage")
        ProgressService = require("modules.progress")
        Errors = require("modules.errors")
        FakeReader = require("spec.fixtures.fake_reader")
        tmp_root = make_dir()
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

    describe("capture", function()
        it("reads XPointer, page and percent", function()
            local book = write_book("epub-content")
            local ui = FakeReader.new{ file = book, title = "三国演义", percent = 0.42 }
            local service = new_service(ui)
            local context, err = service:capture()
            assert.is_nil(err)
            assert.is_equal("xpointer", context.progress.type)
            assert.is_truthy(context.progress.value:match("/p%[1%]"))
            assert.is_equal(0.42, context.progress.percent)
            assert.is_equal(1, context.page)
            assert.is_truthy(context.book.file_name:match("%.epub$"))
            assert.is_equal(#("epub-content"), context.book.size)
            assert.is_equal("三国演义", context.book.title)
        end)

        it("omits unreliable percent values", function()
            local book = write_book("epub-content")
            for _, percent in ipairs({ 0 / 0, math.huge, -1, 2 }) do
                local ui = FakeReader.new{ file = book, percent = percent }
                local service = new_service(ui)
                local context = service:capture()
                assert.is_nil(context.progress.percent)
            end
        end)

        it("rejects fixed-layout and non-EPUB documents", function()
            local book = write_book("%PDF-1.7 fake")
            local ui = FakeReader.new{ file = book, has_pages = true }
            local context, err = new_service(ui):capture()
            assert.is_nil(context)
            assert.is_equal("INVALID_INPUT", err.code)

            ui = FakeReader.new{ file = book, format = "pdf" }
            context, err = new_service(ui):capture()
            assert.is_nil(context)
            assert.is_equal("INVALID_INPUT", err.code)
        end)

        it("rejects an unparsable engine position", function()
            local book = write_book("epub-content")
            local ui = FakeReader.new{ file = book, rolling_xpointer = "not-an-xpointer" }
            local context, err = new_service(ui):capture()
            assert.is_nil(context)
            assert.is_equal("INVALID_INPUT", err.code)
        end)
    end)

    describe("apply", function()
        it("persists a restore point before jumping and verifies page arrival", function()
            local book = write_book("epub-content")
            local ui = FakeReader.new{ file = book, current_page = 3, title = "三国演义" }
            local service, store = new_service(ui)
            local context = service:capture()
            ui.document:forcePage(1)

            local target = FakeReader.target_xpointer(3, 5)
            local captured = run_completion(function(done)
                service:apply(context, { type = "xpointer", value = target }, done)
            end)
            assert.is_nil(captured.err)
            assert.is_equal(1, captured.count)
            assert.is_equal("page", captured.result.match)
            assert.is_equal(3, ui.document:currentPage())
            assert.is_equal(1, ui.document.jump_count)

            local rp = store:get_restore_point()
            assert.is_equal(1, FakeReader.page_from_xpointer(rp.position.value))
            assert.is_equal(book, rp.book.file_path)
        end)

        it("reports restore/apply/check states to the task machine", function()
            local book = write_book("epub-content")
            local ui = FakeReader.new{ file = book, current_page = 3 }
            local service = new_service(ui)
            local context = service:capture()
            ui.document:forcePage(1)

            local states = {}
            local captured = run_completion(function(done)
                service:apply(context, { type = "xpointer", value = FakeReader.target_xpointer(3, 5) }, done, {
                    on_state = function(state) states[#states + 1] = state end,
                })
            end)
            assert.is_nil(captured.err)
            assert.is_equal("persisting_restore", states[1])
            assert.is_equal("applying", states[2])
            assert.is_equal("checking_position", states[3])
        end)

        it("reports an exact engine match when no canonicalization occurs", function()
            local book = write_book("epub-content")
            local ui = FakeReader.new{ file = book, current_page = 2, exact = true }
            local service = new_service(ui)
            local context = service:capture()
            ui.document:forcePage(1)

            local target = FakeReader.target_xpointer(2, 7)
            local captured = run_completion(function(done)
                service:apply(context, { type = "xpointer", value = target }, done)
            end)
            assert.is_nil(captured.err)
            assert.is_equal("exact", captured.result.match)
        end)

        it("does nothing when the imported position equals the current one", function()
            local book = write_book("epub-content")
            local ui = FakeReader.new{ file = book, current_page = 3 }
            local service, store = new_service(ui)
            local context = service:capture()

            local captured = run_completion(function(done)
                service:apply(context, context.progress, done)
            end)
            assert.is_nil(captured.err)
            assert.is_true(captured.result.no_navigation)
            assert.is_equal(0, ui.document.jump_count)
            assert.is_nil(store:get_restore_point())
        end)

        it("refuses to jump when the book changed", function()
            local book = write_book("epub-content")
            local other = write_book("another-book-with-different-size")
            local ui = FakeReader.new{ file = book, current_page = 3 }
            local service = new_service(ui)
            local context = service:capture()

            ui.document.file = other
            local captured = run_completion(function(done)
                service:apply(context, { type = "xpointer", value = FakeReader.target_xpointer(1, 5) }, done)
            end)
            assert.is_equal("CONFLICT", captured.err.code)
            assert.is_equal(0, ui.document.jump_count)
        end)

        it("never jumps when the restore point cannot be persisted", function()
            local book = write_book("epub-content")
            local ui = FakeReader.new{ file = book, current_page = 3 }
            local failing_store = {
                save_restore_point = function()
                    return nil, Errors.new("IO", "disk full")
                end,
            }
            local service = new_service(ui, failing_store)
            local context = service:capture()

            local captured = run_completion(function(done)
                service:apply(context, { type = "xpointer", value = FakeReader.target_xpointer(1, 5) }, done)
            end)
            assert.is_equal("IO", captured.err.code)
            assert.is_equal(0, ui.document.jump_count)
        end)

        it("stops verification when the document is replaced mid-jump", function()
            local book = write_book("epub-content")
            local other = write_book("another-book-with-different-size")
            local ui = FakeReader.new{ file = book, current_page = 3 }
            local service = new_service(ui)
            local context = service:capture()
            ui.document:forcePage(1)

            local real_goto = ui.document.gotoXPointer
            ui.document.gotoXPointer = function(self, xpointer)
                local ok = real_goto(self, xpointer)
                self.file = other
                return ok
            end

            local captured = run_completion(function(done)
                service:apply(context, { type = "xpointer", value = FakeReader.target_xpointer(3, 5) }, done)
            end)
            assert.is_equal("CANCELLED", captured.err.code)
            assert.is_nil(captured.result)
        end)

        it("rolls back and reports uncertainty when arrival cannot be verified", function()
            local book = write_book("epub-content")
            local ui = FakeReader.new{ file = book, current_page = 3 }
            local service, store, clock = new_service(ui)
            local context = service:capture()
            ui.document:forcePage(1)
            ui.document._fail_pages[5] = true

            local captured = run_completion(function(done)
                service:apply(context, { type = "xpointer", value = FakeReader.target_xpointer(5, 5) }, done)
            end)
            clock:drain()

            assert.is_equal(1, captured.count)
            assert.is_equal("UNCERTAIN", captured.err.code)
            assert.is_equal("uncertain", captured.err.outcome)
            assert.is_true(captured.result.rollback)
            assert.is_equal(1, ui.document:currentPage())
            assert.is_nil(store:get_restore_point())
        end)

        it("reports uncertainty when even the rollback cannot be verified", function()
            local book = write_book("epub-content")
            local ui = FakeReader.new{ file = book, current_page = 3 }
            local service, _, clock = new_service(ui)
            local context = service:capture()
            ui.document:forcePage(1)

            -- The engine lands on a different page than requested and the
            -- rollback target is unreachable, so both checks must time out.
            local real_goto = ui.document.gotoXPointer
            ui.document.gotoXPointer = function(self, xpointer)
                local page = FakeReader.page_from_xpointer(xpointer)
                self.jump_count = self.jump_count + 1
                if page == 5 then
                    self._current_page = 6
                    self._current_xpointer = FakeReader.page_start_xpointer(6)
                    return false
                end
                if page == 1 then
                    return false -- stays on page 6
                end
                return real_goto(self, xpointer)
            end

            local captured = run_completion(function(done)
                service:apply(context, { type = "xpointer", value = FakeReader.target_xpointer(5, 5) }, done)
            end)
            clock:drain()

            assert.is_equal(1, captured.count)
            assert.is_equal("UNCERTAIN", captured.err.code)
            assert.is_false(captured.result.rollback)
            assert.is_equal(6, ui.document:currentPage())
        end)
    end)

    describe("undo", function()
        it("returns to the pre-import position and clears the restore point", function()
            local book = write_book("epub-content")
            local ui = FakeReader.new{ file = book, current_page = 3 }
            local service, store = new_service(ui)
            local context = service:capture()
            ui.document:forcePage(1)
            service:apply(context, { type = "xpointer", value = FakeReader.target_xpointer(3, 5) }, function() end)
            assert.is_equal(3, ui.document:currentPage())
            assert.is_truthy(store:get_restore_point())

            ui.document:forcePage(7)
            local captured = run_completion(function(done) service:undo(done) end)
            assert.is_nil(captured.err)
            assert.is_equal(1, ui.document:currentPage())
            assert.is_true(captured.result.cleared)
            assert.is_nil(store:get_restore_point())
        end)

        it("reports NOT_FOUND when no restore point exists", function()
            local book = write_book("epub-content")
            local ui = FakeReader.new{ file = book, current_page = 3 }
            local service = new_service(ui)
            local captured = run_completion(function(done) service:undo(done) end)
            assert.is_equal("NOT_FOUND", captured.err.code)
        end)

        it("refuses to undo in a different book", function()
            local book = write_book("epub-content")
            local other = write_book("another-book-with-different-size")
            local ui = FakeReader.new{ file = book, current_page = 3 }
            local service = new_service(ui)
            local context = service:capture()
            ui.document:forcePage(1)
            service:apply(context, { type = "xpointer", value = FakeReader.target_xpointer(3, 5) }, function() end)

            ui.document.file = other
            local captured = run_completion(function(done) service:undo(done) end)
            assert.is_equal("CONFLICT", captured.err.code)
        end)
    end)
end)
