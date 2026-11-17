describe("random tokens", function()
    local Random

    setup(function()
        require("commonrequire")
        Random = require("modules.random")
    end)

    it("reads hex bytes from the OS random source", function()
        local hex = assert(Random.hex(16))
        assert.is_equal(32, #hex)
        assert.is_truthy(hex:match("^[0-9a-f]+$"))
        local second = assert(Random.hex(16))
        assert.is_true(hex ~= second)
    end)

    it("supports token prefixes", function()
        local token = assert(Random.token("dev-", 8))
        assert.is_truthy(token:match("^dev%-[0-9a-f]+$"))
        assert.is_equal(16, #token:sub(5))
    end)

    it("validates hex strings", function()
        assert.is_true(Random.is_hex("deadbeef", 8))
        assert.is_false(Random.is_hex("deadbeef", 9))
        assert.is_false(Random.is_hex("DEADBEEF"))
        assert.is_false(Random.is_hex(nil))
    end)

    it("rejects invalid byte counts", function()
        for _, count in ipairs({ 0, -1, 1.5, "16" }) do
            local hex, err = Random.hex(count)
            assert.is_nil(hex)
            assert.is_equal("INVALID_INPUT", err.code)
        end
    end)
end)
