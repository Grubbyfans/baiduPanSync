describe("config_store (global device id)", function()
    local ConfigStore, FileUtil, json, lfs
    local tmp_root

    local function make_store(name)
        return ConfigStore:new{ dir = tmp_root .. "/" .. name }
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
        ConfigStore = require("modules.config_store")
        tmp_root = os.tmpname()
        os.remove(tmp_root)
        assert(lfs.mkdir(tmp_root))
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

    it("has no device id before initialization", function()
        local store = make_store("empty")
        local id, err = store:get_device_id()
        assert.is_nil(id)
        assert.is_nil(err)
    end)

    it("generates the device id once and persists it", function()
        local store = make_store("device")
        local id = assert(store:ensure_device_id{ label = "Kindle Voyage" })
        assert.is_truthy(id:match("^kindle%-voyage%-[0-9a-f]+$"))

        local again = assert(store:ensure_device_id{ label = "other" })
        assert.is_equal(id, again)
        assert.is_equal(id, assert(store:get_device_id()))

        local envelope = json.decode(read_all(store:get_path()))
        assert.is_equal(1, envelope.schemaVersion)
        assert.is_equal(id, envelope.data.deviceId)
        assert.is_nil(lfs.attributes(store:get_path() .. ".tmp"))
    end)

    it("uses a safe fallback label", function()
        local store = make_store("fallback")
        local id = assert(store:ensure_device_id{ label = "  !!!  " })
        assert.is_truthy(id:match("^koreader%-[0-9a-f]+$"))
    end)

    it("does not overwrite a corrupt config", function()
        local store = make_store("corrupt")
        local original = "{corrupt"
        FileUtil.mkdir_p(store.dir)
        FileUtil.write_atomic(store:get_path(), original)

        local id, err = store:get_device_id()
        assert.is_nil(id)
        assert.is_equal("INVALID_INPUT", err.code)
        local ensured, ensure_err = store:ensure_device_id{ label = "x" }
        assert.is_nil(ensured)
        assert.is_equal("INVALID_INPUT", ensure_err.code)
        assert.is_equal(original, read_all(store:get_path()))
    end)

    it("does not overwrite a future-version config", function()
        local store = make_store("future")
        local original = '{"schemaVersion":2,"data":{"deviceId":"abcdef0123456789"}}'
        FileUtil.mkdir_p(store.dir)
        FileUtil.write_atomic(store:get_path(), original)

        local id, err = store:get_device_id()
        assert.is_nil(id)
        assert.is_equal("UNSUPPORTED", err.code)
        assert.is_equal(original, read_all(store:get_path()))
    end)

    it("rejects an invalid stored device id", function()
        local store = make_store("invalid")
        local original = '{"schemaVersion":1,"data":{"deviceId":"bad id"}}'
        FileUtil.mkdir_p(store.dir)
        FileUtil.write_atomic(store:get_path(), original)

        local id, err = store:get_device_id()
        assert.is_nil(id)
        assert.is_equal("INVALID_INPUT", err.code)
        assert.is_equal(original, read_all(store:get_path()))
    end)
end)
