describe("storage (local restore-point store)", function()
    local LocalStore, FileUtil, json
    local lfs

    local function make_dir()
        local path = os.tmpname()
        os.remove(path)
        assert(lfs.mkdir(path))
        return path
    end

    local function rm_rf(path)
        local attr = lfs.attributes(path)
        if not attr then return end
        if attr.mode == "directory" then
            for entry in lfs.dir(path) do
                if entry ~= "." and entry ~= ".." then
                    rm_rf(path .. "/" .. entry)
                end
            end
            lfs.rmdir(path)
        else
            os.remove(path)
        end
    end

    local function read_all(path)
        local file = assert(io.open(path, "rb"))
        local text = file:read("*a")
        file:close()
        return text
    end

    local function valid_restore_point()
        return {
            book = {
                file_path = "/books/sanguo.epub",
                file_name = "sanguo.epub",
                title = "三国演义",
                size = 1024,
            },
            position = {
                type = "xpointer",
                value = "/body/DocFragment[1]/body/div/p[3]/text().5",
                percent = 0.25,
            },
            created_at = "2026-11-16T20:00:00+08:00",
            source = "apply_import",
        }
    end

    setup(function()
        require("commonrequire")
        json = require("json")
        lfs = require("libs/libkoreader-lfs")
        LocalStore = require("modules.storage")
        FileUtil = require("modules.file_util")
    end)

    it("starts empty when no state file exists", function()
        local dir = make_dir()
        local store = LocalStore:new{ dir = dir }
        local rp, err = store:get_restore_point()
        assert.is_nil(rp)
        assert.is_nil(err)
        assert.is_false(store:has_restore_point())
        rm_rf(dir)
    end)

    it("saves, reads and clears a restore point", function()
        local dir = make_dir()
        local store = LocalStore:new{ dir = dir .. "/baidupansync" }
        local rp = valid_restore_point()
        assert.is_true(store:save_restore_point(rp))

        local loaded, err = store:get_restore_point()
        assert.is_nil(err)
        assert.is_equal("/books/sanguo.epub", loaded.book.file_path)
        assert.is_equal(0.25, loaded.position.percent)

        local envelope = json.decode(read_all(store:get_state_path()))
        assert.is_equal(1, envelope.schemaVersion)
        assert.is_equal("xpointer", envelope.data.last.position.type)

        assert.is_true(store:has_restore_point())
        assert.is_true(store:clear_restore_point())
        loaded, err = store:get_restore_point()
        assert.is_nil(loaded)
        assert.is_nil(err)

        -- atomic write leaves no temporary file behind
        assert.is_nil(lfs.attributes(store:get_state_path() .. ".tmp"))
        rm_rf(dir)
    end)

    it("rejects invalid restore points without writing", function()
        local dir = make_dir()
        local store = LocalStore:new{ dir = dir }
        local rp = valid_restore_point()
        rp.position = { type = "xpointer", value = "" }
        local ok, err = store:save_restore_point(rp)
        assert.is_nil(ok)
        assert.is_equal("INVALID_INPUT", err.code)
        assert.is_nil(lfs.attributes(store:get_state_path()))
        rm_rf(dir)
    end)

    it("does not overwrite a state file with an unknown version", function()
        local dir = make_dir()
        local store = LocalStore:new{ dir = dir }
        local path = store:get_state_path()
        local original = '{"schemaVersion":2,"data":{}}'
        FileUtil.write_atomic(path, original)

        local rp, err = store:get_restore_point()
        assert.is_nil(rp)
        assert.is_equal("UNSUPPORTED", err.code)
        assert.is_equal(original, read_all(path))

        local saved, save_err = store:save_restore_point(valid_restore_point())
        assert.is_nil(saved)
        assert.is_equal("UNSUPPORTED", save_err.code)
        assert.is_equal(original, read_all(path))
        rm_rf(dir)
    end)

    it("does not treat a corrupt state file as empty", function()
        local dir = make_dir()
        local store = LocalStore:new{ dir = dir }
        local path = store:get_state_path()
        local original = "{corrupt"
        FileUtil.write_atomic(path, original)

        local rp, err = store:get_restore_point()
        assert.is_nil(rp)
        assert.is_equal("INVALID_INPUT", err.code)
        assert.is_equal(original, read_all(path))
        rm_rf(dir)
    end)

    it("reports a corrupted stored restore point instead of hiding it", function()
        local dir = make_dir()
        local store = LocalStore:new{ dir = dir }
        FileUtil.write_atomic(store:get_state_path(),
            '{"schemaVersion":1,"data":{"last":{"book":{},"position":{}}}}')
        local rp, err = store:get_restore_point()
        assert.is_nil(rp)
        assert.is_equal("INVALID_INPUT", err.code)
        rm_rf(dir)
    end)
end)
