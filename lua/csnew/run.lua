local dotnet = require("csnew.dotnet")
local reference = require("csnew.reference")

local M = {}

local job_id
local term_buf = -1

-- Drop // and /* */ comments and trailing commas, leaving string contents
-- alone. Visual Studio and the dotnet CLI accept both in launchSettings.json;
-- a strict JSON decoder does not.
function M.strip_jsonc(text)
	local out = {}
	local i, n = 1, #text
	local in_string = false
	local pending_comma -- index in `out` of a comma that may turn out to be trailing
	while i <= n do
		local c = text:sub(i, i)
		local next_c = text:sub(i + 1, i + 1)
		if in_string then
			out[#out + 1] = c
			if c == "\\" then
				out[#out + 1] = next_c
				i = i + 1
			elseif c == '"' then
				in_string = false
			end
			i = i + 1
		elseif c == "/" and next_c == "/" then
			i = text:find("\n", i, true) or (n + 1)
		elseif c == "/" and next_c == "*" then
			local _, close = text:find("*/", i + 2, true)
			i = close and (close + 1) or (n + 1)
		else
			if c == '"' then
				in_string = true
				pending_comma = nil
			elseif c == "," then
				pending_comma = #out + 1
			elseif c == "}" or c == "]" then
				if pending_comma then
					out[pending_comma] = ""
				end
				pending_comma = nil
			elseif not c:match("%s") then
				pending_comma = nil
			end
			out[#out + 1] = c
			i = i + 1
		end
	end
	return table.concat(out)
end

local function decode_json(text)
	local ok, decoded = pcall(vim.json.decode, text)
	if ok then
		return decoded
	end
	ok, decoded = pcall(vim.json.decode, M.strip_jsonc(text))
	return ok and decoded or nil
end

-- Full launchSettings.json profiles: { { name, env, args }, ... } sorted by name.
-- env comes from environmentVariables (+ applicationUrl as ASPNETCORE_URLS);
-- args comes from commandLineArgs split on whitespace. Only "Project" profiles.
function M.launch_profiles(path)
	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok then
		return {}
	end
	local decoded = decode_json(table.concat(lines, "\n"))
	if type(decoded) ~= "table" or type(decoded.profiles) ~= "table" then
		return {}
	end
	local out = {}
	for name, profile in pairs(decoded.profiles) do
		if type(profile) == "table" and (not profile.commandName or profile.commandName == "Project") then
			local env = {}
			if type(profile.environmentVariables) == "table" then
				for k, v in pairs(profile.environmentVariables) do
					env[k] = tostring(v)
				end
			end
			-- applicationUrl maps to ASPNETCORE_URLS unless the profile sets it explicitly
			if
				type(profile.applicationUrl) == "string"
				and profile.applicationUrl ~= ""
				and env.ASPNETCORE_URLS == nil
			then
				env.ASPNETCORE_URLS = profile.applicationUrl
			end
			local args
			local cmd_args = profile.commandLineArgs
			if type(cmd_args) == "string" and cmd_args ~= "" then
				args = {}
				for a in cmd_args:gmatch("%S+") do
					table.insert(args, a)
				end
			end
			table.insert(out, { name = name, env = env, args = args })
		end
	end
	table.sort(out, function(a, b)
		return a.name < b.name
	end)
	return out
end

-- Names only; derived from launch_profiles so both stay in sync.
function M.parse_launch_profiles(path)
	local names = {}
	for _, profile in ipairs(M.launch_profiles(path)) do
		table.insert(names, profile.name)
	end
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

M.launch_settings_path = launch_settings_path

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
	local root = dotnet.workspace_root() -- before the terminal takes over
	cwd = cwd or root
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
		-- the previous terminal lost its window (the split was closed): drop
		-- it, or every run would leave one more dead buffer behind
		if vim.api.nvim_buf_is_valid(term_buf) then
			pcall(vim.api.nvim_buf_delete, term_buf, { force = true })
		end
		vim.cmd("botright vsplit")
		term_buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_win_set_buf(0, term_buf)
		vim.api.nvim_win_set_width(0, math.max(40, math.floor(vim.o.columns * 0.4)))
	end
	dotnet.remember_root(term_buf, root)
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
		vim.notify("dotnetkit: no runnable project found (needs OutputType=Exe or a Web/Worker SDK)", vim.log.levels.WARN)
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

M.resolve_runnable = resolve_runnable

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
	vim.notify("dotnetkit: stopped", vim.log.levels.INFO)
end

return M
