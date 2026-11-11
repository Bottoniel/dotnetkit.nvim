local function complete(cmdline)
	return vim.fn.getcompletion(cmdline, "cmdline")
end

describe("command completion", function()
	it("offers every kind for an empty first argument of :CsNew", function()
		assert.are.same({ "class", "interface", "record", "enum", "controller", "exception" }, complete("CsNew "))
	end)

	it("filters the kinds by what was typed", function()
		assert.are.same({ "class", "controller" }, complete("CsNew c"))
		assert.are.same({ "enum", "exception" }, complete("CsNew e"))
		assert.are.same({}, complete("CsNew zzz"))
	end)

	it("offers nothing for the type name", function()
		assert.are.same({}, complete("CsNew class "))
		assert.are.same({}, complete("CsNew class Ord"))
	end)

	it("completes templates only as the first argument of :CsNewProject", function()
		assert.are.same({ "webapi", "web" }, complete("CsNewProject w"))
		assert.are.same({}, complete("CsNewProject webapi "))
		assert.are.same({}, complete("CsNewProject webapi con"))
	end)

	it("completes directories for the output dir of :CsNewProject", function()
		local offered = complete("CsNewProject webapi MyApi ")

		assert.is_false(vim.tbl_contains(offered, "console"))
		assert.are.same(vim.fn.getcompletion("", "dir"), offered)
	end)
end)

describe("commands", function()
	it("are all defined", function()
		for _, name in ipairs({
			"CsNew", "CsNewProject", "CsAddRef", "CsRemoveRef", "CsSlnAdd", "CsSlnRemove",
			"CsAddPkg", "CsListPkg", "CsRemovePkg", "CsUpdatePkg", "CsBuild", "CsRun", "CsWatch",
			"CsStop", "CsDebugRun", "CsDebugAttach", "CsDebugStop",
			"EfMigrate", "EfUpdate", "EfRemove", "EfList", "EfScript",
		}) do
			assert.are.same(2, vim.fn.exists(":" .. name), name)
		end
	end)
end)
