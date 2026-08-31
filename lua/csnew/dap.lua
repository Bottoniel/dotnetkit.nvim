local dotnet = require("csnew.dotnet")
local reference = require("csnew.reference")
local projects = require("csnew.projects")

local M = {}

local function netcoredbg_path()
	local mason_dir = vim.fn.stdpath("data") .. "/mason/bin/"
	if vim.fn.has("win32") == 1 then
		local exe = mason_dir .. "netcoredbg.exe"
		if vim.fn.executable(exe) == 1 then
			return exe
		end
	end
	local mason = mason_dir .. "netcoredbg"
	if vim.fn.executable(mason) == 1 then
		return mason
	end
	if vim.fn.executable("netcoredbg") == 1 then
		return "netcoredbg"
	end
	return nil
end

function M.pick_newest_tfm(paths)
	if not paths or #paths == 0 then
		return nil
	end
	local scored = {}
	for _, path in ipairs(paths) do
		local tfm = path:match("/bin/Debug/([^/]+)/") or ""
		local major, minor = tfm:match("net(%d+)%.(%d+)")
		local score = major and (tonumber(major) * 10000 + tonumber(minor)) or -1
		table.insert(scored, { path = path, score = score, tfm = tfm })
	end
	table.sort(scored, function(a, b)
		if a.score ~= b.score then
			return a.score < b.score
		end
		if a.tfm ~= b.tfm then
			return a.tfm < b.tfm
		end
		return a.path > b.path
	end)
	return scored[#scored].path
end

local function assembly_name(csproj)
	local ok, lines = pcall(vim.fn.readfile, csproj)
	if ok then
		local name = table.concat(lines, "\n"):match("<AssemblyName>%s*(.-)%s*</AssemblyName>")
		if name and name ~= "" then
			return name
		end
	end
	return vim.fn.fnamemodify(csproj, ":t:r")
end

local function find_dll(project)
	local dir = vim.fn.isdirectory(project) == 1 and project or vim.fn.fnamemodify(project, ":h")
	local name = vim.fn.isdirectory(project) == 1 and vim.fn.fnamemodify(project, ":t:r")
		or assembly_name(project)
	local matches = vim.fn.glob(dir .. "/bin/Debug/*/" .. name .. ".dll", false, true)
	if #matches > 0 then
		return M.pick_newest_tfm(matches)
	end
	return M.pick_newest_tfm(vim.fn.glob(dir .. "/bin/Debug/*/*.dll", false, true))
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
