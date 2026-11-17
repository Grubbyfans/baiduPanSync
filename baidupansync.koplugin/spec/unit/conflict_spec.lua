describe("conflict classification", function()
    local Conflict, Hash

    local function baseline(overrides)
        local value = {
            remote_state = "present",
            base_revision = 5,
            base_remote_fingerprint = string.rep("a", 64),
        }
        for key, item in pairs(overrides or {}) do value[key] = item end
        return value
    end

    setup(function()
        require("commonrequire")
        Conflict = require("modules.conflict")
        Hash = require("modules.hash")
    end)

    it("fingerprints the XPointer and ignores percent", function()
        local a = Conflict.position_fingerprint{
            type = "xpointer", value = "/body/p[3]/text().5", percent = 0.2,
        }
        local b = Conflict.position_fingerprint{
            type = "xpointer", value = "/body/p[3]/text().5",
        }
        local c = Conflict.position_fingerprint{
            type = "xpointer", value = "/body/p[4]/text().1", percent = 0.2,
        }
        assert.is_true(Hash.is_sha256_hex(a))
        assert.is_equal(a, b)
        assert.is_true(a ~= c)
        assert.is_nil(Conflict.position_fingerprint{ type = "page", value = 3 })
    end)

    it("treats a missing baseline as first contact", function()
        local result = Conflict.classify(nil, string.rep("b", 64), 1)
        assert.is_equal("first_contact", result.kind)
        assert.is_true(result.remote_changed)
        assert.is_true(result.requires_confirmation)
    end)

    it("classifies absent remote states", function()
        local absent = baseline{ remote_state = "absent" }
        local unchanged = Conflict.classify(absent, nil, nil)
        assert.is_equal("unchanged", unchanged.kind)
        assert.is_false(unchanged.remote_changed)

        local created = Conflict.classify(absent, string.rep("b", 64), 1)
        assert.is_equal("remote_created", created.kind)
        assert.is_true(created.requires_confirmation)
    end)

    it("detects unchanged records by raw fingerprint", function()
        local result = Conflict.classify(baseline(), string.rep("a", 64), 5)
        assert.is_equal("unchanged", result.kind)
        assert.is_false(result.remote_changed)
        assert.is_false(result.requires_confirmation)
    end)

    it("detects the same revision with different content", function()
        local result = Conflict.classify(baseline(), string.rep("b", 64), 5)
        assert.is_equal("same_revision_different_record", result.kind)
        assert.is_true(result.same_revision)
        assert.is_true(result.requires_confirmation)
    end)

    it("detects a changed revision", function()
        local result = Conflict.classify(baseline(), string.rep("b", 64), 6)
        assert.is_equal("remote_changed", result.kind)
        assert.is_false(result.same_revision)
        assert.is_true(result.remote_changed)
    end)

    it("detects a deleted remote record", function()
        local result = Conflict.classify(baseline(), nil, nil)
        assert.is_equal("remote_deleted", result.kind)
        assert.is_true(result.remote_changed)
    end)

    it("decides whether navigation is needed by position only", function()
        assert.is_false(Conflict.needs_navigation(
            { type = "xpointer", value = "/body/p[1]", percent = 0.1 },
            { type = "xpointer", value = "/body/p[1]", percent = 0.9 }))
        assert.is_true(Conflict.needs_navigation(
            { type = "xpointer", value = "/body/p[1]" },
            { type = "xpointer", value = "/body/p[2]" }))
    end)
end)
