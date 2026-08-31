local dotnet = require("csnew.dotnet")
local reference = require("csnew.reference")

local M = {}

local job_id
local term_buf = -1

function M.parse_launch_profiles(path)
	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok then
		return {}
	end
	local decoded
	ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
	if not ok or type(decoded) ~= "table" or type(decoded.profiles) ~= "table" then
		return {}
	end
	local names = {}
	for name, profile in pairs(decoded.profiles) do
		if type(profile) == "table" and (not profile.commandName or profile.commandName == "Project") then
			table.insert(names, name)
		end
	end
	table.sort(names)
	return names
end

local function project_dir(path)
	if vim.fn.isdirectory(path) == 1 then
		return path
	end
	return vim.fn.fnamemodify(path, ":h")
end

local function launch_settings_path(startup)
	return project_dir(startup) .. "/Properties/launchSettings.json"
end

function M.compose_args(kind, project, profile)
	if kind == "watch" then
		local args = { "watch", "--project", project, "run" }
		if profile and profile ~= "" then
			table.insert(args, "--launch-profile")
			table.insert(args, profile)
		end
		return args
	end
	local args = { "run", "--project", project }
	if profile and profile ~= "" then
		table.insert(args, "--launch-profile")
		table.insert(args, profile)
	end
	return args
end

local function stop_job()
	if job_id then
		pcall(vim.fn.jobstop, job_id)
		job_id = nil
	end
end

local function open_term(cmd, opts)
	if vim.fn.has("nvim-0.11") == 1 then
		return vim.fn.jobstart(cmd, vim.tbl_extend("force", opts, { term = true }))
	end
	return vim.fn.termopen(cmd, opts)
end

local function start_term(args, cwd)
	stop_job()
	local cmd = { "dotnet", unpack(args) }
	cwd = cwd or dotnet.workspace_root()
	local win
	if vim.api.nvim_buf_is_valid(term_buf) then
		for _, w in ipairs(vim.api.nvim_list_wins()) do
			if vim.api.nvim_win_get_buf(w) == term_buf then
				win = w
				break
			end
		end
	end
	if win then
		vim.api.nvim_set_current_win(win)
		local new_buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_win_set_buf(win, new_buf)
		pcall(vim.api.nvim_buf_delete, term_buf, { force = true })
		term_buf = new_buf
	else
		vim.cmd("botright vsplit")
		term_buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_win_set_buf(0, term_buf)
		vim.api.nvim_win_set_width(0, math.max(40, math.floor(vim.o.columns * 0.4)))
	end
	job_id = open_term(cmd, { cwd = cwd })
end

local function with_profile(kind, project)
	local profiles = M.parse_launch_profiles(launch_settings_path(project))
	local cwd = project_dir(project)
	local function go(profile)
		start_term(M.compose_args(kind, project, profile), cwd)
	end
	if #profiles == 0 then
		go(nil)
		return
	end
	if #profiles == 1 then
		go(profiles[1])
		return
	end
	vim.ui.select(profiles, { prompt = "Launch profile:" }, function(choice)
		if choice then
			go(choice)
		end
	end)
end

local function resolve_runnable(prompt, preset, go)
	if preset and preset ~= "" then
		go(dotnet.normalize(preset))
		return
	end
	local root = dotnet.workspace_root()
	local runnable = {}
	for _, p in ipairs(dotnet.find_projects(root)) do
		if dotnet.is_runnable(p) then
			table.insert(runnable, p)
		end
	end
	local current = reference.current_project()
	if current then
		current = dotnet.normalize(current)
	end
	if current and vim.tbl_contains(runnable, current) then
		go(current)
		return
	end
	if #runnable == 0 then
		vim.notify("csnew: no runnable project found (needs OutputType=Exe or a Web/Worker SDK)", vim.log.levels.WARN)
		return
	end
	if #runnable == 1 then
		go(runnable[1])
		return
	end
	vim.ui.select(runnable, {
		prompt = prompt,
		format_item = function(p)
			return dotnet.relative_display(p, root)
		end,
	}, function(choice)
		if choice then
			go(choice)
		end
	end)
end

function M.run(opts)
	opts = opts or {}
	resolve_runnable("Run project:", opts.project, function(project)
		with_profile("run", project)
	end)
end

function M.watch(opts)
	opts = opts or {}
	resolve_runnable("Watch project:", opts.project, function(project)
		with_profile("watch", project)
	end)
end

function M.stop()
	stop_job()
	if vim.api.nvim_buf_is_valid(term_buf) then
		pcall(vim.api.nvim_buf_delete, term_buf, { force = true })
		term_buf = -1
	end
	vim.notify("csnew: stopped", vim.log.levels.INFO)
end

return M
