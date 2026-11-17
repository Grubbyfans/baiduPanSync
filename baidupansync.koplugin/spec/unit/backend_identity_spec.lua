describe("backend_identity", function()
    local BackendIdentity, Hash

    setup(function()
        require("commonrequire")
        BackendIdentity = require("modules.backend_identity")
        Hash = require("modules.hash")
    end)

    it("normalizes only the confirmed WebDAV equivalences", function()
        local cases = {
            { "http://Example.COM:80/koreader/", "http://example.com/koreader/" },
            { "https://example.com:443/koreader", "https://example.com/koreader/" },
            { "HTTPS://Sync.Example.com/koreader///", "https://sync.example.com/koreader/" },
            { "http://192.168.1.10:8080/koreader", "http://192.168.1.10:8080/koreader/" },
            { "http://[::1]:8080/dav/", "http://[::1]:8080/dav/" },
        }
        for _, case in ipairs(cases) do
            local normalized, err = BackendIdentity.normalize_webdav(case[1])
            assert.is_nil(err, case[1])
            assert.is_equal(case[2], normalized, case[1])
        end
    end)

    it("preserves path and username case", function()
        local lower = assert(BackendIdentity.compute{
            type = "webdav", root_url = "http://host/KoReader/", username = "alice",
        })
        local upper = assert(BackendIdentity.compute{
            type = "webdav", root_url = "http://host/koreader/", username = "alice",
        })
        local upper_user = assert(BackendIdentity.compute{
            type = "webdav", root_url = "http://host/KoReader/", username = "Alice",
        })
        assert.is_true(lower ~= upper)
        assert.is_true(lower ~= upper_user)
    end)

    it("produces the same id for equivalent URLs", function()
        local a = assert(BackendIdentity.compute{
            type = "webdav", root_url = "HTTP://Example.com:80/koreader", username = "u",
        })
        local b = assert(BackendIdentity.compute{
            type = "webdav", root_url = "http://example.com/koreader/", username = "u",
        })
        assert.is_true(Hash.is_sha256_hex(a))
        assert.is_equal(a, b)
    end)

    it("ignores password/token fields", function()
        local a = assert(BackendIdentity.compute{
            type = "webdav", root_url = "http://host/dav/", username = "u",
        })
        local b = assert(BackendIdentity.compute{
            type = "webdav", root_url = "http://host/dav/", username = "u",
            password = "secret", token = "xyz",
        })
        assert.is_equal(a, b)
    end)

    it("is unambiguous when field values could concatenate", function()
        local a = assert(BackendIdentity.compute{
            type = "webdav", root_url = "http://host/a/", username = "bc",
        })
        local b = assert(BackendIdentity.compute{
            type = "webdav", root_url = "http://host/ab/", username = "c",
        })
        assert.is_true(a ~= b)
    end)

    it("rejects unsafe or unconfirmed WebDAV URLs", function()
        local bad = {
            "http://user:pass@host/dav/",
            "http://host/dav/?x=1",
            "http://host/dav/#frag",
            "http://host/dav/ ",
            "ftp://host/dav/",
            "http://host:0/dav/",
            "http://host:70000/dav/",
            "http:///dav/",
        }
        for _, url in ipairs(bad) do
            local normalized, err = BackendIdentity.normalize_webdav(url)
            assert.is_nil(normalized, url)
            assert.is_equal("INVALID_INPUT", err.code, url)
        end
    end)

    it("normalizes Baidu application directories", function()
        local forms = { "apps/x", "/apps/x", "apps/x/", "//apps//x//" }
        local first
        for _, dir in ipairs(forms) do
            local normalized = assert(BackendIdentity.normalize_baidu_dir(dir))
            assert.is_equal("/apps/x/", normalized)
            local id = assert(BackendIdentity.compute{
                type = "baidu", app_key = "key", app_dir = dir, user_id = "user",
            })
            first = first or id
            assert.is_equal(first, id)
        end
        assert.is_nil(BackendIdentity.normalize_baidu_dir("/"))
    end)

    it("isolates Baidu identities by key, directory and user", function()
        local base = assert(BackendIdentity.compute{
            type = "baidu", app_key = "key", app_dir = "/apps/x/", user_id = "user",
        })
        local other_key = assert(BackendIdentity.compute{
            type = "baidu", app_key = "key2", app_dir = "/apps/x/", user_id = "user",
        })
        local other_dir = assert(BackendIdentity.compute{
            type = "baidu", app_key = "key", app_dir = "/apps/y/", user_id = "user",
        })
        local other_user = assert(BackendIdentity.compute{
            type = "baidu", app_key = "key", app_dir = "/apps/x/", user_id = "user2",
        })
        assert.is_true(base ~= other_key)
        assert.is_true(base ~= other_dir)
        assert.is_true(base ~= other_user)
    end)

    it("rejects missing fields and unknown types", function()
        local cases = {
            { type = "webdav", root_url = "http://host/dav/" },
            { type = "webdav", username = "u" },
            { type = "baidu", app_key = "key", app_dir = "/apps/x/" },
            { type = "baidu", app_key = "key", user_id = "u" },
            { type = "dropbox" },
        }
        for _, profile in ipairs(cases) do
            local id, err = BackendIdentity.compute(profile)
            assert.is_nil(id)
            assert.is_equal("INVALID_INPUT", err.code)
        end
        local id, err = BackendIdentity.compute(nil)
        assert.is_nil(id)
        assert.is_equal("INVALID_INPUT", err.code)
    end)
end)
