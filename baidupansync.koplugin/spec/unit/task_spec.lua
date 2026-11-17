describe("task state machine", function()
    local Task

    setup(function()
        require("commonrequire")
        Task = require("modules.task")
    end)

    it("starts idle and records transitions", function()
        local seen = {}
        local task = Task:new{
            kind = "export",
            on_state = function(state) seen[#seen + 1] = state end,
        }
        assert.is_equal("idle", task:get_state())
        assert.is_false(task:is_terminal())
        assert.is_true(task:transition("preparing"))
        assert.is_equal("preparing", task:get_state())
        assert.is_equal("preparing", seen[1])
        assert.is_equal(2, #task.history)
    end)

    it("rejects illegal transitions", function()
        local task = Task:new{ kind = "export" }
        local ok, err = task:transition("done")
        assert.is_nil(ok)
        assert.is_equal("INVALID_INPUT", err.code)
        assert.is_equal("idle", task:get_state())
        assert.is_false(task:can_transition("writing"))
    end)

    it("walks the export lifecycle", function()
        local task = Task:new{ kind = "export" }
        for _, state in ipairs({
            "preparing", "writing", "verifying", "committing_local", "done",
        }) do
            assert.is_true(task:transition(state), state)
        end
        assert.is_true(task:is_terminal())
        assert.is_nil(task:transition("preparing"))
        assert.is_false(task:cancel())
    end)

    it("walks the import lifecycle", function()
        local task = Task:new{ kind = "import" }
        for _, state in ipairs({
            "preparing", "reading_remote", "awaiting_confirm", "rechecking",
            "persisting_restore", "applying", "checking_position",
            "committing_local", "done",
        }) do
            assert.is_true(task:transition(state), state)
        end
        assert.is_true(task:is_terminal())
    end)

    it("allows a no-navigation import to commit the baseline", function()
        local task = Task:new{ kind = "import" }
        for _, state in ipairs({
            "preparing", "reading_remote", "awaiting_confirm", "rechecking",
            "committing_local", "done",
        }) do
            assert.is_true(task:transition(state), state)
        end
    end)

    it("supports failed, cancelled and uncertain terminal states", function()
        local failed = Task:new{}
        failed:transition("preparing")
        assert.is_true(failed:transition("failed"))
        assert.is_true(failed:is_terminal())

        local cancelled = Task:new{}
        assert.is_true(cancelled:cancel("user"))
        assert.is_equal("cancelled", cancelled:get_state())

        local uncertain = Task:new{}
        uncertain:transition("preparing")
        uncertain:transition("writing")
        assert.is_true(uncertain:transition("uncertain"))
        assert.is_true(uncertain:is_terminal())
    end)

    it("survives a reporter error", function()
        local task = Task:new{
            kind = "export",
            on_state = function() error("reporter") end,
        }
        assert.is_true(task:transition("preparing"))
        assert.is_equal("preparing", task:get_state())
    end)

    it("rejects unknown target states", function()
        local task = Task:new{}
        local ok, err = task:transition("bogus")
        assert.is_nil(ok)
        assert.is_equal("INVALID_INPUT", err.code)
    end)
end)
