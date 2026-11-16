describe("export store (local progress JSON directory)", function()
    local ExportStore, ProgressRecord
    local lfs

    local tmp_root

    local function make_dir()
        local path = os.tmpname()
        os.remove(path)
        assert(lfs.mkdir(path))
        return path
    end

    local function record()
        return {
            schemaVersion = 1,
            recordType = "local-progress",
            book = {
                title = "三国演义",
                fileName = "sanguo.epub",
                format = "epub",
                size = 1024,
            },
            progress = {
                type = "xpointer",
                value = "/body/DocFragment[1]/body/div/p[3]/text().5",
                percent = 0.25,
            },
            exportedAt = "2026-11-16T20:00:00+08:00",
        }
    end

    setup(function()
        require("commonrequire")
        lfs = require("libs/libkoreader-lfs")
        ExportStore = require("modules.export_store")
        ProgressRecord = require("modules.progress_record")
        tmp_root = make_dir()
    end)

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

    before_each(function()
        rm_rf(tmp_root .. "/exports")
    end)

    teardown(function()
        rm_rf(tmp_root)
    end)

    it("saves a record into the export directory", function()
        local store = ExportStore:new{ dir = tmp_root .. "/exports" }
        local path, err = store:save(record(), { filename = "progress.json" })
        assert.is_nil(err)
        assert.is_equal(tmp_root .. "/exports/progress.json", path)

        local text = assert(io.open(path, "rb")):read("*a")
        assert.is_truthy(text:match('"recordType"'))
        assert.is_nil(lfs.attributes(path .. ".tmp"))
    end)

    it("rejects invalid records", function()
        local store = ExportStore:new{ dir = tmp_root .. "/exports" }
        local bad = record()
        bad.progress.value = ""
        local path, err = store:save(bad)
        assert.is_nil(path)
        assert.is_equal("INVALID_INPUT", err.code)
    end)

    it("sanitizes file names and avoids collisions", function()
        local store = ExportStore:new{ dir = tmp_root .. "/exports" }
        local path = assert(store:save(record(), { filename = "../../my record.json" }))
        assert.is_truthy(path:match("/my_record%.json$"))

        local second = assert(store:save(record(), { filename = "my_record.json" }))
        assert.is_truthy(second:match("/my_record%-2%.json$"))
    end)

    it("lists valid and invalid entries and loads a record", function()
        local dir = tmp_root .. "/exports"
        local store = ExportStore:new{ dir = dir }
        local good = assert(store:save(record(), { filename = "good.json" }))
        local broken = dir .. "/broken.json"
        local file = assert(io.open(broken, "wb"))
        file:write("{not json")
        file:close()

        local entries, err = store:list()
        assert.is_nil(err)
        assert.is_equal(2, #entries)
        local by_name = {}
        for _, entry in ipairs(entries) do by_name[entry.name] = entry end
        assert.is_true(by_name["good.json"].valid)
        assert.is_equal("三国演义", by_name["good.json"].record.book.title)
        assert.is_false(by_name["broken.json"].valid)
        assert.is_equal("INVALID_INPUT", by_name["broken.json"].error.code)

        local loaded, load_err = store:load(good)
        assert.is_nil(load_err)
        assert.is_equal(0.25, loaded.progress.percent)
    end)

    it("returns an empty list when the export directory does not exist", function()
        local store = ExportStore:new{ dir = tmp_root .. "/missing" }
        local entries, err = store:list()
        assert.is_nil(err)
        assert.is_equal(0, #entries)
    end)

    it("refuses to read files outside the export directory", function()
        local store = ExportStore:new{ dir = tmp_root .. "/exports" }
        local loaded, err = store:load("/etc/passwd")
        assert.is_nil(loaded)
        assert.is_equal("INVALID_INPUT", err.code)
    end)

    it("validates records on load rather than trusting the extension", function()
        local dir = tmp_root .. "/exports"
        local store = ExportStore:new{ dir = dir }
        assert(store:save(record(), { filename = "seed.json" }))
        local path = dir .. "/evil.json"
        local file = assert(io.open(path, "wb"))
        file:write([[{"schemaVersion":1,"recordType":"local-progress",
            "book":{"fileName":"a.epub","format":"epub","size":-1},
            "progress":{"type":"xpointer","value":"/body/p[1]","percent":0.5}}]])
        file:close()
        local loaded, err = store:load(path)
        assert.is_nil(loaded)
        assert.is_equal("INVALID_INPUT", err.code)
    end)
end)
