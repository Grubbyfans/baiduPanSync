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
        assert.is_equal("0.8.4", meta.version)
        assert.is_equal("0.8.4", Plugin.version)
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
        assert.is_nil(instance.exports)
        assert.is_truthy(instance.progress)
        assert.is_nil(instance.engine)
        assert.is_truthy(instance.identity)
        assert.is_truthy(instance.state)
        assert.is_truthy(instance.config)
        assert.is_truthy(instance.settings_dir:match("/baidupansync$"))
        assert.is_nil(instance.exports_dir)
    end)

    it("registers a single entry opening the persistent plugin page", function()
        local fake_ui = { menu = { registerToMainMenu = function() end } }
        local instance = Plugin:new{ ui = fake_ui }
        local menu_items = {}
        instance:addToMainMenu(menu_items)
        local menu = menu_items.baidupansync
        assert.is_truthy(menu)
        assert.is_equal("more_tools", menu.sorting_hint)
        assert.is_nil(menu.sub_item_table)
        assert.is_equal("function",type(menu.callback))
        local actions=require("ui/menu").actions(instance)
        assert.is_equal(10,#actions)
        for _,item in ipairs(actions)do assert.is_equal("function",type(item.callback))end
    end)

    it("removes local backup entry points", function()
        assert.is_nil(Plugin.onExportProgress)
        assert.is_nil(Plugin.onImportProgress)
        local instance=Plugin:new{ui={menu={registerToMainMenu=function()end}}}
        for _,item in ipairs(require('ui/menu').actions(instance)) do
            assert.is_false(item.id=='export_progress' or item.id=='import_progress')
        end
    end)
    it("loads cloud UI and exposes the library without an open EPUB", function()
        local ui=require("ui/cloud_dialog")
        assert.is_equal("function",type(ui.confirm))
        assert.is_equal("function",type(ui.library))
        local instance=Plugin:new{ui={menu={registerToMainMenu=function()end}}}
        local menu={};instance:addToMainMenu(menu)
        local library=require("ui/menu").actions(instance)[5]
        assert.is_nil(library.enabled_func)
        assert.is_false(instance:isCurrentBookSupported())
    end)

end)
