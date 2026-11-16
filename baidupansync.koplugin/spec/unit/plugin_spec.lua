describe("plugin entry point", function()
    local plugin_dir = os.getenv("BPS_PLUGIN_ROOT")
    local Plugin, meta

    setup(function()
        require("commonrequire")
        assert(plugin_dir, "BPS_PLUGIN_ROOT must be set by spec/run.sh")
        Plugin = dofile(plugin_dir .. "/main.lua")
        meta = dofile(plugin_dir .. "/_meta.lua")
    end)

    it("loads metadata and exposes a version", function()
        assert.is_true(type(meta.fullname) == "string" and #meta.fullname > 0)
        assert.is_equal("0.1.0", meta.version)
        assert.is_equal("0.1.0", Plugin.version)
    end)

    it("initializes a local store and service under the settings directory", function()
        local registered = 0
        local fake_ui = {
            menu = {
                registerToMainMenu = function() registered = registered + 1 end,
            },
        }
        local instance = Plugin:new{ ui = fake_ui }
        assert.is_equal(1, registered)
        assert.is_truthy(instance.store)
        assert.is_truthy(instance.exports)
        assert.is_truthy(instance.progress)
        assert.is_truthy(instance.settings_dir:match("/baidupansync$"))
        assert.is_truthy(instance.exports_dir:match("/baidupansync/exports$"))
    end)

    it("registers only the three Stage A menu entries", function()
        local fake_ui = { menu = { registerToMainMenu = function() end } }
        local instance = Plugin:new{ ui = fake_ui }
        local menu_items = {}
        instance:addToMainMenu(menu_items)
        local menu = menu_items.baidupansync
        assert.is_truthy(menu)
        assert.is_equal("more_tools", menu.sorting_hint)
        assert.is_equal(3, #menu.sub_item_table)
        for _, item in ipairs(menu.sub_item_table) do
            assert.is_equal("function", type(item.callback))
        end
    end)

    it("disables the book-specific import entry without an EPUB", function()
        local fake_ui = { menu = { registerToMainMenu = function() end } }
        local instance = Plugin:new{ ui = fake_ui }
        local menu_items = {}
        instance:addToMainMenu(menu_items)
        local import_item = menu_items.baidupansync.sub_item_table[2]
        assert.is_false(import_item.enabled_func())
        assert.is_false(instance:isCurrentBookSupported())
        assert.is_false(instance:hasRestorePoint())
    end)
end)
