local function fresh()
	package.loaded["csnew"] = nil
	return require("csnew")
end

describe("configuration merge", function()
	it("has working defaults without any options", function()
		local csnew = fresh()
		csnew.setup()
		local config = csnew.get_config()

		assert.are.same({ "restore", "lsp_restart" }, config.dotnet.after_change)
		assert.is_true(config.dap.build)
		assert.are.same("Debug", config.dap.configuration)
	end)

	it("merges sections key by key", function()
		local csnew = fresh()
		csnew.setup({ dap = { configuration = "Release" }, ef = { context = "ShopContext" } })
		local config = csnew.get_config()

		assert.are.same("Release", config.dap.configuration)
		assert.is_true(config.dap.build)
		assert.is_true(config.dap.just_my_code)
		assert.are.same("ShopContext", config.ef.context)
	end)

	it("keeps the defaults of a section given as an empty table", function()
		local csnew = fresh()
		csnew.setup({ dap = {}, dotnet = {} })
		local config = csnew.get_config()

		assert.is_true(config.dap.build)
		assert.are.same("auto", config.dap.ui)
		assert.are.same({ "restore", "lsp_restart" }, config.dotnet.after_change)
	end)

	it("replaces lists instead of merging them", function()
		local csnew = fresh()
		csnew.setup({ dotnet = { after_change = { "clean" } } })

		assert.are.same({ "clean" }, csnew.get_config().dotnet.after_change)
	end)

	it("lets an empty list disable every after_change step", function()
		local csnew = fresh()
		csnew.setup({ dotnet = { after_change = {} } })

		assert.are.same({}, csnew.get_config().dotnet.after_change)
		assert.is_false(require("csnew.dotnet").after_change_has("lsp_restart"))
	end)

	it("is reachable under the plugin's name too", function()
		assert.are.equal(require("csnew"), require("dotnetkit"))
	end)
end)
