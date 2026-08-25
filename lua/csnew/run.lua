local dotnet = require("csnew.dotnet")
local projects = require("csnew.projects")

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

local function start_term(args)
	stop_job()
	local cmd = { "dotnet", unpack(args) }
	if vim.api.nvim_buf_is_valid(term_buf) then
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			if vim.api.nvim_win_get_buf(win) == term_buf then
				vim.api.nvim_set_current_win(win)
				job_id = vim.fn.termopen(cmd, { cwd = dotnet.workspace_root() })
				return
			end
		end
	end
	vim.cmd("botright vsplit")
	term_buf = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_win_set_buf(0, term_buf)
	vim.api.nvim_win_set_width(0, math.max(40, math.floor(vim.o.columns * 0.4)))
	job_id = vim.fn.termopen(cmd, { cwd = dotnet.workspace_root() })
end

local function with_profile(kind, pair)
	local profiles = M.parse_launch_profiles(launch_settings_path(pair.startup or pair.project))
	local function go(profile)
		start_term(M.compose_args(kind, pair.project, profile))
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

function M.run(opts)
	opts = opts or {}
	if opts.project then
		with_profile("run", { project = dotnet.normalize(opts.project), startup = opts.project })
		return
	end
	projects.pick_pair(function(pair)
		with_profile("run", pair)
	end, { project = "Run project:", startup = "Startup project:", confirm = "Run:" })
end

function M.watch(opts)
	opts = opts or {}
	if opts.project then
		with_profile("watch", { project = dotnet.normalize(opts.project), startup = opts.project })
		return
	end
	projects.pick_pair(function(pair)
		with_profile("watch", pair)
	end, { project = "Watch project:", startup = "Startup project:", confirm = "Watch:" })
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
