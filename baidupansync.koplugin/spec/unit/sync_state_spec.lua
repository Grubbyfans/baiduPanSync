describe("sync_state (backendId + bookId baselines)", function()
    local SyncState, FileUtil, json, lfs
    local tmp_root, store
    local backend_a = string.rep("a", 64)
    local backend_b = string.rep("b", 64)
    local book_a = string.rep("c", 64)
    local book_b = string.rep("d", 64)

    local function baseline(overrides)
        local value = {
            remote_state = "present",
            base_revision = 3,
            base_remote_fingerprint = string.rep("e", 64),
            last_progress_fingerprint = string.rep("f", 64),
            updated_at = "2026-11-16T20:00:00+08:00",
            last_write_id = string.rep("1", 32),
        }
        for key, item in pairs(overrides or {}) do value[key] = item end
        return value
    end

    local function read_all(path)
        local file = assert(io.open(path, "rb"))
        local text = file:read("*a")
        file:close()
        return text
    end

    setup(function()
        require("commonrequire")
        lfs = require("libs/libkoreader-lfs")
        json = require("json")
        FileUtil = require("modules.file_util")
        SyncState = require("modules.sync_state")
        tmp_root = os.tmpname()
        os.remove(tmp_root)
        assert(lfs.mkdir(tmp_root))
        store = SyncState:new{ dir = tmp_root .. "/state" }
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

    it("has no baseline before the first sync", function()
        local value, err = store:get(backend_a, book_a)
        assert.is_nil(value)
        assert.is_nil(err)
    end)

    it("stores and reads a present baseline", function()
        assert.is_true(store:put(backend_a, book_a, baseline()))
        local value = assert(store:get(backend_a, book_a))
        assert.is_equal(3, value.base_revision)
        assert.is_equal(string.rep("e", 64), value.base_remote_fingerprint)
        local envelope = json.decode(read_all(store:get_path()))
        assert.is_equal(1, envelope.schemaVersion)
        assert.is_equal(3, envelope.data.baselines[backend_a][book_a].base_revision)
        assert.is_nil(lfs.attributes(store:get_path() .. ".tmp"))
    end)

    it("isolates baselines by backend and by book", function()
        store:put(backend_a, book_a, baseline{ base_revision = 1 })
        store:put(backend_a, book_b, baseline{ base_revision = 2 })
        store:put(backend_b, book_a, baseline{ base_revision = 9 })

        assert.is_equal(1, store:get(backend_a, book_a).base_revision)
        assert.is_equal(2, store:get(backend_a, book_b).base_revision)
        assert.is_equal(9, store:get(backend_b, book_a).base_revision)
        assert.is_nil(store:get(backend_b, book_b))
    end)

    it("stores an explicit absent remote marker", function()
        local absent = { remote_state = "absent", updated_at = "2026-11-16T20:00:00+08:00" }
        assert.is_true(store:put(backend_a, book_a, absent))
        local value = assert(store:get(backend_a, book_a))
        assert.is_equal("absent", value.remote_state)
        assert.is_nil(value.base_remote_fingerprint)
    end)

    it("deletes one baseline without touching the others", function()
        store:put(backend_a, book_a, baseline{})
        store:put(backend_a, book_b, baseline{})
        assert.is_true(store:delete(backend_a, book_a))
        assert.is_nil(store:get(backend_a, book_a))
        assert.is_truthy(store:get(backend_a, book_b))
        assert.is_true(store:delete(backend_a, book_a)) -- idempotent
    end)

    it("rejects invalid ids and baselines", function()
        local id, err = store:get("short", book_a)
        assert.is_nil(id)
        assert.is_equal("INVALID_INPUT", err.code)

        local ok, baseline_err = store:put(backend_a, book_a, baseline{ base_revision = 0 })
        assert.is_nil(ok)
        assert.is_equal("INVALID_INPUT", baseline_err.code)

        ok, baseline_err = store:put(backend_a, book_a, baseline{
            base_remote_fingerprint = "short",
        })
        assert.is_nil(ok)
        assert.is_equal("INVALID_INPUT", baseline_err.code)

        ok, baseline_err = store:put(backend_a, book_a, baseline{ remote_state = "gone" })
        assert.is_nil(ok)
        assert.is_equal("INVALID_INPUT", baseline_err.code)
    end)

    it("does not overwrite a corrupt or future-version file", function()
        local cases = {
            { "{corrupt", "INVALID_INPUT" },
            { '{"schemaVersion":2,"data":{"baselines":{}}}', "UNSUPPORTED" },
            { '{"schemaVersion":1,"data":{}}', "INVALID_INPUT" },
        }
        for _, case in ipairs(cases) do
            FileUtil.mkdir_p(store.dir)
            FileUtil.write_atomic(store:get_path(), case[1])
            local value, err = store:get(backend_a, book_a)
            assert.is_nil(value)
            assert.is_equal(case[2], err.code)

            local ok, put_err = store:put(backend_a, book_a, baseline{})
            assert.is_nil(ok)
            assert.is_equal(case[2], put_err.code)
            assert.is_equal(case[1], read_all(store:get_path()))
        end
    end)
end)
