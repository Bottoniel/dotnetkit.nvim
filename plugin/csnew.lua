if vim.g.loaded_csnew then
	return
end
vim.g.loaded_csnew = true

vim.api.nvim_create_user_command("CsNew", function(opts)
	require("csnew").command(opts)
end, {
	nargs = "*",
	complete = function()
		return require("csnew.templates").kinds
	end,
	desc = "Create a C# type in the current directory",
})

local function expand(arg)
	if arg and arg ~= "" then
		return vim.fn.expand(arg)
	end
	return nil
end

vim.api.nvim_create_user_command("CsAddRef", function(opts)
	local f = opts.fargs or {}
	require("csnew.reference").add({ project = expand(f[1]), reference = expand(f[2]) })
end, {
	nargs = "*",
	complete = "file",
	desc = "Add a ProjectReference to the current .csproj",
})

vim.api.nvim_create_user_command("CsRemoveRef", function(opts)
	local f = opts.fargs or {}
	require("csnew.reference").remove({ project = expand(f[1]), reference = expand(f[2]) })
end, {
	nargs = "*",
	complete = "file",
	desc = "Remove a ProjectReference from the current .csproj",
})

vim.api.nvim_create_user_command("CsSlnAdd", function(opts)
	local f = opts.fargs or {}
	require("csnew.sln").add({ project = expand(f[1]) })
end, {
	nargs = "*",
	complete = "file",
	desc = "Add a project to the solution",
})

vim.api.nvim_create_user_command("CsSlnRemove", function(opts)
	local f = opts.fargs or {}
	require("csnew.sln").remove({ project = expand(f[1]) })
end, {
	nargs = "*",
	complete = "file",
	desc = "Remove a project from the solution",
})

vim.api.nvim_create_user_command("CsAddPkg", function(opts)
	local f = opts.fargs or {}
	require("csnew.package").add({ name = f[1], version = f[2] })
end, {
	nargs = "*",
	desc = "Add a NuGet package to the current .csproj",
})

vim.api.nvim_create_user_command("EfMigrate", function(opts)
	require("csnew.ef").migrate({ name = opts.fargs[1] })
end, {
	nargs = "?",
	desc = "Add an EF Core migration",
})

vim.api.nvim_create_user_command("EfUpdate", function(opts)
	require("csnew.ef").update({ target = opts.fargs[1] })
end, {
	nargs = "?",
	desc = "Update the database to a migration (empty = latest, 0 = revert all)",
})

vim.api.nvim_create_user_command("EfRemove", function()
	require("csnew.ef").remove()
end, {
	nargs = 0,
	desc = "Remove the last EF Core migration",
})

vim.api.nvim_create_user_command("EfList", function()
	require("csnew.ef").list()
end, {
	nargs = 0,
	desc = "List EF Core migrations in a buffer",
})

vim.api.nvim_create_user_command("EfScript", function()
	require("csnew.ef").script()
end, {
	nargs = 0,
	desc = "Generate an idempotent SQL script from migrations",
})

vim.api.nvim_create_user_command("CsBuild", function(opts)
	require("csnew.build").run({ target = expand(opts.fargs[1]) })
end, {
	nargs = "?",
	complete = "file",
	desc = "Build the solution or project and populate the quickfix list",
})

vim.api.nvim_create_user_command("CsListPkg", function(opts)
	require("csnew.package").list({ project = expand(opts.fargs[1]) })
end, {
	nargs = "?",
	complete = "file",
	desc = "List NuGet packages (with outdated versions)",
})

vim.api.nvim_create_user_command("CsRemovePkg", function(opts)
	require("csnew.package").remove({ name = opts.fargs[1] })
end, {
	nargs = "*",
	desc = "Remove a NuGet package from the current .csproj",
})

vim.api.nvim_create_user_command("CsUpdatePkg", function(opts)
	require("csnew.package").update({ name = opts.fargs[1], version = opts.fargs[2] })
end, {
	nargs = "*",
	desc = "Update a NuGet package to the latest or given version",
})

vim.api.nvim_create_user_command("CsNewProject", function(opts)
	require("csnew.newproject").create({
		template = opts.fargs[1],
		name = opts.fargs[2],
		outdir = opts.fargs[3],
	})
end, {
	nargs = "*",
	complete = function()
		return require("csnew.newproject").templates
	end,
	desc = "Create a new .NET project (dotnet new)",
})

vim.api.nvim_create_user_command("CsRun", function(opts)
	require("csnew.run").run({ project = expand(opts.fargs[1]) })
end, {
	nargs = "?",
	complete = "file",
	desc = "Run a .NET project (dotnet run)",
})

vim.api.nvim_create_user_command("CsWatch", function(opts)
	require("csnew.run").watch({ project = expand(opts.fargs[1]) })
end, {
	nargs = "?",
	complete = "file",
	desc = "Watch and run a .NET project (dotnet watch)",
})

vim.api.nvim_create_user_command("CsStop", function()
	require("csnew.run").stop()
end, {
	nargs = 0,
	desc = "Stop the running CsRun / CsWatch job",
})

vim.api.nvim_create_user_command("CsDebugRun", function(opts)
	require("csnew.dap").debug_run({ project = expand(opts.fargs[1]) })
end, {
	nargs = "?",
	complete = "file",
	desc = "Debug the current .NET project with nvim-dap",
})

vim.api.nvim_create_user_command("CsDebugAttach", function(opts)
	require("csnew.dap").debug_attach({ project = expand(opts.fargs[1]) })
end, {
	nargs = "?",
	complete = "file",
	desc = "Attach nvim-dap to a running .NET process (e.g. :CsRun / :CsWatch)",
})

vim.api.nvim_create_user_command("CsDebugStop", function()
	require("csnew.dap").debug_stop()
end, {
	nargs = 0,
	desc = "Stop the active nvim-dap session",
})
