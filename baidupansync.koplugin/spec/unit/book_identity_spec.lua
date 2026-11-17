describe("book_identity (full SHA-256 + cache)", function()
    local BookIdentity, Hash, lfs
    local tmp_root, identity

    local function write_file(name, content)
        local path = tmp_root .. "/" .. name
        local file = assert(io.open(path, "wb"))
        file:write(content)
        file:close()
        return path
    end

    local function identify(path, opts)
        local captured = { count = 0, starts = 0, finishes = 0 }
        local merged = opts or {}
        merged.schedule = merged.schedule or function(cb) cb() end
        local user_start = merged.on_hash_start
        local user_finish = merged.on_hash_finish
        merged.on_hash_start = function(total)
            captured.starts = captured.starts + 1
            if user_start then user_start(total) end
        end
        merged.on_hash_finish = function()
            captured.finishes = captured.finishes + 1
            if user_finish then user_finish() end
        end
        identity:identify(path, merged, function(err, result)
            captured.count = captured.count + 1
            captured.err = err
            captured.identity = result
        end)
        return captured
    end

    setup(function()
        require("commonrequire")
        lfs = require("libs/libkoreader-lfs")
        Hash = require("modules.hash")
        BookIdentity = require("modules.book_identity")
        tmp_root = os.tmpname()
        os.remove(tmp_root)
        assert(lfs.mkdir(tmp_root))
        identity = BookIdentity:new{ dir = tmp_root .. "/identity" }
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

    it("computes the full digest on first use", function()
        local path = write_file("a.epub", "abc")
        local result = identify(path)
        assert.is_equal(1, result.count)
        assert.is_nil(result.err)
        assert.is_equal(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            result.identity.content_sha256)
        assert.is_equal(result.identity.content_sha256, result.identity.book_id)
        assert.is_false(result.identity.cached)
        assert.is_equal(1, result.starts)
        assert.is_equal(1, result.finishes)
    end)

    it("reuses the cache when size and mtime are unchanged", function()
        local path = write_file("b.epub", "content-b")
        identify(path)
        local second = identify(path)
        assert.is_nil(second.err)
        assert.is_true(second.identity.cached)
        assert.is_equal(0, second.starts)
        assert.is_equal(0, second.finishes)
    end)

    it("recomputes after the file changes", function()
        local path = write_file("c.epub", "first")
        local first = identify(path)
        write_file("c.epub", "second-content")
        local second = identify(path)
        assert.is_nil(second.err)
        assert.is_false(second.identity.cached)
        assert.is_true(first.identity.content_sha256 ~= second.identity.content_sha256)
        assert.is_equal(Hash.sha256_text("second-content"), second.identity.content_sha256)
    end)

    it("recomputes when the cache is invalidated", function()
        local path = write_file("d.epub", "abc")
        identify(path)
        assert.is_true(identity:invalidate(path))
        local again = identify(path)
        assert.is_false(again.identity.cached)
        assert.is_equal(1, again.starts)
    end)

    it("ignores a corrupt or future-version cache and rebuilds it", function()
        local path = write_file("e.epub", "abc")
        for _, cache_text in ipairs({
            "{corrupt",
            '{"schemaVersion":2,"data":{"entries":{}}}',
            '{"schemaVersion":1,"data":{"entries":{"x":1}}}',
        }) do
            local cache_path = identity:get_path()
            local file = assert(io.open(cache_path, "wb"))
            file:write(cache_text)
            file:close()
            local result = identify(path)
            assert.is_nil(result.err)
            assert.is_false(result.identity.cached)
            assert.is_equal(Hash.sha256_text("abc"), result.identity.content_sha256)
        end
    end)

    it("does not return or cache a cancelled digest", function()
        local path = write_file("f.epub", string.rep("x", 64))
        local calls = 0
        local result = identify(path, {
            chunk_size = 8,
            schedule = function(cb) cb() end,
            is_cancelled = function()
                calls = calls + 1
                return calls > 1
            end,
        })
        assert.is_nil(result.identity)
        assert.is_equal("CANCELLED", result.err.code)
        assert.is_nil(identity:get_cached(path))
    end)

    it("hashes again with use_cache=false", function()
        local path = write_file("g.epub", "abc")
        identify(path)
        local forced = identify(path, { use_cache = false })
        assert.is_false(forced.identity.cached)
        assert.is_equal(1, forced.starts)
    end)

    it("reports missing files and directories", function()
        local missing = identify(tmp_root .. "/missing.epub")
        assert.is_nil(missing.identity)
        assert.is_equal("NOT_FOUND", missing.err.code)

        local directory = identify(tmp_root)
        assert.is_nil(directory.identity)
        assert.is_equal("INVALID_INPUT", directory.err.code)
    end)
end)
