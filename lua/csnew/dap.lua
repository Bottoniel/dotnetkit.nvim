local dotnet = require("csnew.dotnet")
local reference = require("csnew.reference")
local projects = require("csnew.projects")

local M = {}

local function netcoredbg_path()
	local mason = vim.fn.stdpath("data") .. "/mason/bin/netcoredbg"
	if vim.fn.executable(mason) == 1 then
		return mason
	end
	if vim.fn.executable("netcoredbg") == 1 then
		return "netcoredbg"
	end
	return nil
end

local function find_dll(project)
	local dir = vim.fn.isdirectory(project) == 1 and project or vim.fn.fnamemodify(project, ":h")
	local name = vim.fn.fnamemodify(project, ":t:r")
	local matches = vim.fn.glob(dir .. "/bin/Debug/*/" .. name .. ".dll", false, true)
	if #matches > 0 then
		table.sort(matches)
		return matches[#matches]
	end
	matches = vim.fn.glob(dir .. "/bin/Debug/*/*.dll", false, true)
	return matches[1]
end

function M.setup()
	if vim.g.csnew_dap_loaded then
		return
	end
	local ok, dap = pcall(require, "dap")
	if not ok then
		return
	end
	local dbg = netcoredbg_path()
	if not dbg then
		return
	end
	dap.adapters.coreclr = {
		type = "executable",
		command = dbg,
		args = { "--interpreter=vscode" },
	}
	dap.configurations.cs = dap.configurations.cs or {}
	table.insert(dap.configurations.cs, {
		type = "coreclr",
		name = "csnew: launch",
		request = "launch",
		program = function()
			return M.resolve_dll()
		end,
	})
	vim.g.csnew_dap_loaded = true
end

function M.resolve_dll(project)
	project = project or reference.current_project()
	if not project then
		return vim.fn.input("Path to dll: ", vim.fn.getcwd() .. "/bin/Debug/", "file")
	end
	local dll = find_dll(project)
	if dll then
		return dll
	end
	return vim.fn.input("Path to dll: ", vim.fn.fnamemodify(project, ":h") .. "/bin/Debug/", "file")
end

function M.debug_run(opts)
	opts = opts or {}
	local ok, dap = pcall(require, "dap")
	if not ok then
		vim.notify("csnew: nvim-dap is not installed", vim.log.levels.ERROR)
		return
	end
	if not netcoredbg_path() then
		vim.notify("csnew: netcoredbg not found (MasonInstall netcoredbg)", vim.log.levels.ERROR)
		return
	end

	local function launch(project)
		local dll = find_dll(project)
		if not dll then
			vim.notify("csnew: no Debug dll found, build the project first", vim.log.levels.ERROR)
			return
		end
		dap.run({
			type = "coreclr",
			name = "csnew: launch",
			request = "launch",
			program = dll,
			cwd = vim.fn.isdirectory(project) == 1 and project or vim.fn.fnamemodify(project, ":h"),
		})
	end

	if opts.project then
		launch(dotnet.normalize(opts.project))
		return
	end
	local current = reference.current_project()
	if current then
		launch(current)
		return
	end
	projects.pick_one("Debug project:", nil, function(choice)
		if choice then
			launch(choice)
		end
	end)
end

return M
