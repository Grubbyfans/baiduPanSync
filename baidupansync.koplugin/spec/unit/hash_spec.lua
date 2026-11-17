describe("hash (chunked SHA-256)", function()
    local Hash, lfs
    local tmp_root

    local function write_file(name, content)
        local path = tmp_root .. "/" .. name
        local file = assert(io.open(path, "wb"))
        file:write(content)
        file:close()
        return path
    end

    -- A queue-based scheduler, like UIManager: it avoids deep recursion when a
    -- test uses a 1-byte chunk size.
    local function run(path, opts)
        opts = opts or {}
        local queue = {}
        opts.schedule = function(callback) queue[#queue + 1] = callback end
        local captured = { count = 0 }
        Hash.file(path, opts, function(err, digest, stat)
            captured.count = captured.count + 1
            captured.err = err
            captured.digest = digest
            captured.stat = stat
        end)
        while #queue > 0 do
            local callback = table.remove(queue, 1)
            callback()
        end
        return captured
    end

    setup(function()
        require("commonrequire")
        lfs = require("libs/libkoreader-lfs")
        Hash = require("modules.hash")
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

    it("matches known digests", function()
        assert.is_equal(
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            Hash.sha256_text(""))
        assert.is_equal(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            Hash.sha256_text("abc"))
    end)

    it("hashes empty and small files", function()
        local empty = write_file("empty.bin", "")
        local result = run(empty, { schedule = function(cb) cb() end })
        assert.is_nil(result.err)
        assert.is_equal("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            result.digest)
        assert.is_equal(0, result.stat.size)

        local small = write_file("small.bin", "abc")
        result = run(small, { schedule = function(cb) cb() end })
        assert.is_equal(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            result.digest)
    end)

    it("produces the same digest for any chunk size", function()
        local content = string.rep("0123456789abcdef", 1000)
        local path = write_file("chunked.bin", content)
        local expected = Hash.sha256_text(content)
        for _, chunk_size in ipairs({ 1, 7, 1024, 1024 * 1024 }) do
            local result = run(path, {
                chunk_size = chunk_size,
                schedule = function(cb) cb() end,
            })
            assert.is_nil(result.err)
            assert.is_equal(expected, result.digest)
        end
    end)

    it("reports monotonic progress and calls back once", function()
        local content = string.rep("x", 100)
        local path = write_file("progress.bin", content)
        local seen = {}
        local captured = run(path, {
            chunk_size = 10,
            schedule = function(cb) cb() end,
            on_progress = function(done) seen[#seen + 1] = done end,
        })
        assert.is_equal(1, captured.count)
        assert.is_nil(captured.err)
        assert.is_true(#seen >= 2)
        for i = 2, #seen do
            assert.is_true(seen[i] >= seen[i - 1])
        end
        assert.is_equal(100, seen[#seen])
    end)

    it("cancels without returning a digest", function()
        local path = write_file("cancel.bin", string.rep("x", 100))
        local calls = 0
        local result = run(path, {
            chunk_size = 10,
            schedule = function(cb) cb() end,
            is_cancelled = function()
                calls = calls + 1
                return calls > 1
            end,
        })
        assert.is_equal(1, result.count)
        assert.is_nil(result.digest)
        assert.is_equal("CANCELLED", result.err.code)
    end)

    it("detects a file that changes while hashing", function()
        local path = write_file("changing.bin", string.rep("x", 100))
        local changed = false
        local result = run(path, {
            chunk_size = 10,
            schedule = function(cb) cb() end,
            on_progress = function(done)
                if not changed and done > 0 then
                    changed = true
                    local file = assert(io.open(path, "wb"))
                    file:write("short")
                    file:close()
                end
            end,
        })
        assert.is_equal(1, result.count)
        assert.is_nil(result.digest)
        assert.is_truthy(result.err)
        assert.is_true(result.err.code == "CONFLICT" or result.err.code == "IO")
    end)

    it("reports missing files and directories", function()
        local missing = run(tmp_root .. "/nope.bin", { schedule = function(cb) cb() end })
        assert.is_nil(missing.digest)
        assert.is_equal("NOT_FOUND", missing.err.code)

        local directory = run(tmp_root, { schedule = function(cb) cb() end })
        assert.is_nil(directory.digest)
        assert.is_equal("INVALID_INPUT", directory.err.code)
    end)

    it("fails cleanly when the progress callback raises", function()
        local path = write_file("callback-error.bin", "abc")
        local result = run(path, {
            chunk_size = 1,
            schedule = function(cb) cb() end,
            on_progress = function() error("boom") end,
        })
        assert.is_nil(result.digest)
        assert.is_equal("INVALID_INPUT", result.err.code)
        assert.is_equal(1, result.count)
    end)
end)
