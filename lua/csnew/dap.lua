local dotnet = require("csnew.dotnet")
local namespace = require("csnew.namespace")
local reference = require("csnew.reference")
local projects = require("csnew.projects")
local run = require("csnew.run")
local build = require("csnew.build")

local M = {}

-- Whether coreclr is the adapter registered here, as opposed to one the user
-- (or another plugin) had already set up.
local own_adapter = false

-- The dap section of the merged config (defaults < setup() < .csnew.lua).
-- Read lazily so merely opening a .cs never pulls in repoconfig or nvim-dap.
local function dap_config()
	local ok, csnew = pcall(require, "csnew")
	local cfg = ok and csnew.get_config() or nil
	return (cfg and cfg.dap) or {}
end

local function project_dir(path)
	if vim.fn.isdirectory(path) == 1 then
		return path
	end
	return vim.fn.fnamemodify(path, ":h")
end

-- Resolve the netcoredbg binary: explicit config > Mason > PATH.
function M.netcoredbg_path()
	local cfg = dap_config()
	if cfg.netcoredbg and vim.fn.executable(cfg.netcoredbg) == 1 then
		return cfg.netcoredbg
	end
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

-- Kept public: given candidate dll paths, pick the one under the newest TFM.
function M.pick_newest_tfm(paths)
	if not paths or #paths == 0 then
		return nil
	end
	local scored = {}
	for _, path in ipairs(paths) do
		local tfm = path:match("/bin/[^/]+/([^/]+)/") or ""
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

-- A directory given as the project stands for the .csproj inside it.
local function as_csproj(project)
	if project and vim.fn.isdirectory(project) == 1 then
		return namespace.find_csproj(project, project) or project
	end
	return project
end

-- The name the project is shown under ("My.Api" for My.Api.csproj).
local function project_label(project)
	if vim.fn.isdirectory(project) == 1 then
		return vim.fn.fnamemodify(project, ":t")
	end
	return vim.fn.fnamemodify(project, ":t:r")
end

-- <AssemblyName>, defaulting to the project file name. nil when it is an
-- MSBuild expression that cannot be evaluated here.
local function assembly_name(project)
	local csproj = as_csproj(project)
	local label = project_label(csproj)
	if vim.fn.isdirectory(csproj) == 1 then
		return label
	end
	local ok, lines = pcall(vim.fn.readfile, csproj)
	if not ok then
		return label
	end
	local name = table.concat(lines, "\n"):match("<AssemblyName>%s*(.-)%s*</AssemblyName>")
	if not name or name == "" then
		return label
	end
	name = name:gsub("%$%(MSBuildProjectName%)", function()
		return label
	end)
	if name:find("$(", 1, true) then
		return nil
	end
	return name
end

-- Sorted names of the files and of the directories directly inside dir.
-- Reads the directory rather than globbing: 'wildignore' commonly lists
-- *.dll or */bin/*, which would hide the very files being looked for.
local function list_dir(dir)
	local files, dirs = {}, {}
	local handle = vim.uv.fs_scandir(dir)
	while handle do
		local name, kind = vim.uv.fs_scandir_next(handle)
		if not name then
			break
		end
		if kind ~= "file" and kind ~= "directory" then
			-- symlink, or a filesystem that does not report the type
			local stat = vim.uv.fs_stat(dir .. "/" .. name)
			kind = stat and stat.type or "file"
		end
		table.insert(kind == "directory" and dirs or files, name)
	end
	table.sort(files)
	table.sort(dirs)
	return files, dirs
end

-- Find the built dll for a project (.csproj path or directory), honoring
-- dap.configuration (default "Debug") and RID-specific output folders.
local function find_dll(project, configuration)
	configuration = configuration or dap_config().configuration or "Debug"
	local base = project_dir(project) .. "/bin/" .. configuration

	-- bin/<cfg>/<tfm>/ first, then bin/<cfg>/<tfm>/<rid>/ (RID-specific builds)
	local levels = { {}, {} }
	local _, tfms = list_dir(base)
	for _, tfm in ipairs(tfms) do
		local tfm_dir = base .. "/" .. tfm
		table.insert(levels[1], tfm_dir)
		local _, rids = list_dir(tfm_dir)
		for _, rid in ipairs(rids) do
			table.insert(levels[2], tfm_dir .. "/" .. rid)
		end
	end

	local name = assembly_name(project)
	if name then
		for _, dirs in ipairs(levels) do
			local matches = {}
			for _, dir in ipairs(dirs) do
				local dll = dir .. "/" .. name .. ".dll"
				if vim.uv.fs_stat(dll) then
					table.insert(matches, dll)
				end
			end
			if #matches > 0 then
				return M.pick_newest_tfm(matches)
			end
		end
	end

	-- The name did not match (it is set somewhere else, e.g. in
	-- Directory.Build.props). Only a launchable assembly has a
	-- runtimeconfig.json next to it; every other dll is a dependency.
	for _, dirs in ipairs(levels) do
		local matches = {}
		for _, dir in ipairs(dirs) do
			for _, file in ipairs((list_dir(dir))) do
				local stem = file:match("^(.*)%.runtimeconfig%.json$")
				if stem and vim.uv.fs_stat(dir .. "/" .. stem .. ".dll") then
					table.insert(matches, dir .. "/" .. stem .. ".dll")
				end
			end
		end
		if #matches > 0 then
			return M.pick_newest_tfm(matches)
		end
	end
	return nil
end

function M.resolve_dll(project)
	project = project or reference.current_project()
	local configuration = dap_config().configuration or "Debug"
	if not project then
		return vim.fn.input("Path to dll: ", vim.fn.getcwd() .. "/bin/" .. configuration .. "/", "file")
	end
	local dll = find_dll(project, configuration)
	if dll then
		return dll
	end
	return vim.fn.input("Path to dll: ", project_dir(project) .. "/bin/" .. configuration .. "/", "file")
end

-- Every .csproj in the workspace that can actually be launched.
local function runnable_projects()
	local list = {}
	for _, p in ipairs(dotnet.find_projects(dotnet.workspace_root())) do
		if dotnet.is_runnable(p) then
			table.insert(list, p)
		end
	end
	return list
end

-- Non-interactive profile resolution for the provider path: applies the single
-- launchSettings profile when there is exactly one. With several, picking needs
-- a prompt, which belongs to :CsDebugRun, so the provider applies none.
local function auto_profile(project, cfg)
	if cfg.profile == false or not project then
		return nil, nil
	end
	local profiles = run.launch_profiles(run.launch_settings_path(project))
	if #profiles == 1 then
		return profiles[1].env, profiles[1].args
	end
	return nil, nil
end

-- Interactive profile resolution for :CsDebugRun (same UX as :CsRun):
-- 0 profiles -> none, 1 -> automatic, several -> picker. cb(env, args).
function M.with_launch_profile(project, cfg, cb)
	if cfg.profile == false then
		cb(nil, nil)
		return
	end
	local profiles = run.launch_profiles(run.launch_settings_path(project))
	if #profiles == 0 then
		cb(nil, nil)
		return
	end
	if #profiles == 1 then
		cb(profiles[1].env, profiles[1].args)
		return
	end
	vim.ui.select(profiles, {
		prompt = "Launch profile:",
		format_item = function(p)
			return p.name
		end,
	}, function(choice)
		if choice then
			cb(choice.env, choice.args)
		else
			vim.notify("dotnetkit: debug launch cancelled", vim.log.levels.INFO)
		end
	end)
end

-- The port a URL binds. "localhost" and wildcard hosts are probed on loopback,
-- which is where a dev server actually listens.
local function probe_host(host)
	if host == "localhost" or host == "+" or host == "*" or host == "0.0.0.0" or host == "::" or host == "[::]" then
		return "127.0.0.1"
	end
	return (host:gsub("^%[", ""):gsub("%]$", ""))
end

-- Endpoints the launch profile will bind, taken from ASPNETCORE_URLS.
-- Kept public: pure parsing, worth exercising on its own.
function M.profile_endpoints(env)
	local urls = env and env.ASPNETCORE_URLS
	if type(urls) ~= "string" or urls == "" then
		return {}
	end
	local out, seen = {}, {}
	for url in urls:gmatch("[^;,]+") do
		url = vim.trim(url)
		local host, port = url:match("^%a[%w+.%-]*://(%[[^%]]+%]):(%d+)")
		if not host then
			host, port = url:match("^%a[%w+.%-]*://([^:/]+):(%d+)")
		end
		port = tonumber(port)
		if host and port and not seen[port] then
			seen[port] = true
			table.insert(out, { url = url, host = probe_host(host), port = port })
		end
	end
	return out
end

-- Is someone listening there? A connect answers that directly; binding does
-- not, because libuv sets SO_REUSEADDR and the bind succeeds anyway.
-- Kept public: used by the pre-flight and easy to verify in isolation.
function M.port_listening(host, port, timeout)
	local client = vim.uv.new_tcp()
	if not client then
		return false
	end
	local done, listening = false, false
	local ok = pcall(client.connect, client, host, port, function(err)
		listening = err == nil
		done = true
		pcall(function()
			client:close()
		end)
	end)
	if not ok then
		pcall(function()
			client:close()
		end)
		return false
	end
	vim.wait(timeout or 200, function()
		return done
	end, 10)
	if not done then
		pcall(function()
			client:close()
		end)
	end
	return listening
end

-- Best effort: who holds the port. Returns pid, name or nil.
local function port_owner(port)
	local function first_pid(out)
		return tonumber((out or ""):match("%d+"))
	end
	local function capture(cmd)
		if vim.fn.executable(cmd[1]) ~= 1 then
			return nil
		end
		local res = vim.system(cmd, { text = true }):wait(2000)
		return res.code == 0 and res.stdout or nil
	end

	local pid
	if vim.fn.has("win32") == 1 then
		local out = capture({ "netstat", "-ano", "-p", "tcp" })
		for line in (out or ""):gmatch("[^\r\n]+") do
			if line:match(":" .. port .. "%s") and line:match("LISTENING") then
				pid = tonumber(line:match("(%d+)%s*$"))
				break
			end
		end
	else
		pid = first_pid(capture({ "lsof", "-ti", "tcp:" .. port, "-sTCP:LISTEN" }))
		if not pid then
			local out = capture({ "ss", "-ltnp" })
			for line in (out or ""):gmatch("[^\r\n]+") do
				if line:match(":" .. port .. "%s") then
					pid = tonumber(line:match("pid=(%d+)"))
					break
				end
			end
		end
	end
	if not pid then
		return nil
	end

	-- /proc/<pid>/cmdline is NUL-separated: prefer the dll being hosted
	-- ("dotnet App.dll"), else the name of the executable itself.
	local name
	local file = io.open("/proc/" .. pid .. "/cmdline", "rb")
	if file then
		local raw = file:read("*a") or ""
		file:close()
		local executable
		for arg in raw:gmatch("[^%z]+") do
			executable = executable or arg:match("[^/\\]+$")
			local dll = arg:match("([^/\\]+%.dll)$")
			if dll then
				name = dll
				break
			end
		end
		name = name or executable
	end
	if not name then
		name = capture({ "ps", "-p", tostring(pid), "-o", "comm=" })
		name = name and vim.trim(name) or nil
	end
	return pid, name
end

-- Terminate the process holding the port, escalating to SIGKILL, and report
-- whether the port actually came free.
local function free_port(pid, host, port)
	local function signal(sig)
		if vim.fn.has("win32") == 1 then
			vim.system({ "taskkill", "/PID", tostring(pid), "/F" }):wait(3000)
		else
			vim.system({ "kill", sig, tostring(pid) }):wait(2000)
		end
	end
	local function gone(ms)
		local deadline = vim.uv.now() + ms
		while vim.uv.now() < deadline do
			if not M.port_listening(host, port, 100) then
				return true
			end
			vim.wait(150)
		end
		return not M.port_listening(host, port, 100)
	end
	signal("-TERM")
	if gone(3000) then
		return true
	end
	vim.notify("dotnetkit: pid " .. pid .. " ignored SIGTERM, forcing", vim.log.levels.WARN)
	signal("-KILL")
	return gone(2000)
end

-- Kestrel reports a taken port as an unhandled AddressInUseException in the
-- middle of a debug session, which reads like a crash. Check first and offer
-- the two things you actually want: attach to what is already there, or
-- replace it. Disable with dap.port_check = false.
-- cb(true) when the launch may go ahead, cb(false) when it must not.
local function check_ports(env, cfg, cb)
	if cfg.port_check == false then
		cb(true)
		return
	end
	local busy
	for _, ep in ipairs(M.profile_endpoints(env)) do
		if M.port_listening(ep.host, ep.port) then
			busy = ep
			break
		end
	end
	if not busy then
		cb(true)
		return
	end

	local pid, name = port_owner(busy.port)
	local who = pid and (" (pid " .. pid .. (name and (", " .. name) or "") .. ")") or ""
	local choices = { "Attach to it instead" }
	if pid then
		table.insert(choices, "Kill it and launch")
	end
	vim.list_extend(choices, { "Launch anyway", "Cancel" })

	vim.ui.select(choices, {
		prompt = busy.url .. " is already in use" .. who .. ":",
	}, function(choice)
		if choice == "Attach to it instead" then
			cb(false)
			-- The owner of the port is already known, so attach to it directly
			-- instead of asking again. Deferred: the launch this replaces has
			-- to unwind first.
			vim.schedule(function()
				M.debug_attach({ pid = pid })
			end)
		elseif choice == "Kill it and launch" then
			if free_port(pid, busy.host, busy.port) then
				cb(true)
			else
				vim.notify("dotnetkit: port " .. busy.port .. " is still in use", vim.log.levels.ERROR)
				cb(false)
			end
		elseif choice == "Launch anyway" then
			cb(true)
		else
			cb(false)
		end
	end)
end

local function launch_name(project)
	return "dotnetkit: launch" .. (project and (" " .. project_label(project)) or "")
end

-- Build the project unless dap.build is off. cb(ok).
local function build_project(project, cfg, cb)
	if cfg.build == false then
		cb(true)
		return
	end
	build.run({
		target = project,
		configuration = cfg.configuration,
		on_done = function(ok)
			cb(ok) -- on failure build.run already notified and opened the quickfix
		end,
	})
end

-- The dll to launch, once the ports the profile binds are known to be free.
-- cb(dll), or cb(nil) when the launch must not go ahead. With `ask`, a dll
-- that cannot be found is asked for instead of being an error.
local function locate_program(project, env, cfg, ask, cb)
	local dll = find_dll(project, cfg.configuration)
	if not dll and ask then
		dll = M.resolve_dll(project)
		if dll == "" then
			cb(nil)
			return
		end
	end
	if not dll then
		local configuration = cfg.configuration or "Debug"
		vim.notify(
			("dotnetkit: no %s dll found under %s/bin/%s%s"):format(
				configuration,
				project_dir(project),
				configuration,
				cfg.build == false and ", build the project first" or ""
			),
			vim.log.levels.ERROR
		)
		cb(nil)
		return
	end
	check_ports(env, cfg, function(free)
		cb(free and dll or nil)
	end)
end

local function launch_dap_config(project, dll, env, args, cfg)
	local config = {
		type = "coreclr",
		name = launch_name(project),
		request = "launch",
		program = dll,
		cwd = project_dir(project),
		stopAtEntry = cfg.stop_at_entry or false,
		justMyCode = cfg.just_my_code ~= false,
	}
	if env and next(env) then
		config.env = env
	end
	if args and #args > 0 then
		config.args = args
	end
	return config
end

-- Launch config for the dap provider. Expensive/interactive fields stay lazy so
-- nothing is resolved (or prompted) unless the user actually picks this config.
-- Picking it goes through the same steps as :CsDebugRun: build, find the dll,
-- check the profile's ports.
function M.launch_configuration(project, cfg)
	cfg = cfg or dap_config()
	local env, args
	if project then
		env, args = auto_profile(project, cfg)
	end
	local config = {
		type = "coreclr",
		name = launch_name(project),
		request = "launch",
		program = function()
			local abort = require("dap").ABORT
			if not project then
				local dll = M.resolve_dll(nil)
				return (dll and dll ~= "") and dll or abort
			end
			-- nvim-dap resumes a coroutine returned here with its own and waits
			-- to be resumed with the value, so the build does not block the editor
			return coroutine.create(function(dap_co)
				build_project(project, cfg, function(ok)
					if not ok then
						coroutine.resume(dap_co, abort)
						return
					end
					locate_program(project, env, cfg, true, function(dll)
						coroutine.resume(dap_co, dll or abort)
					end)
				end)
			end)
		end,
		stopAtEntry = cfg.stop_at_entry or false,
		justMyCode = cfg.just_my_code ~= false,
	}
	if project then
		config.cwd = project_dir(project)
		if env and next(env) then
			config.env = env
		end
		if args and #args > 0 then
			config.args = args
		end
	end
	return config
end

-- The dotnet CLI, build servers and language servers all run on "dotnet" too,
-- but none of them is the app. Attaching to `dotnet run` in particular looks
-- right and never hits a breakpoint: the app is its child process.
local SDK_VERBS = {
	add = true,
	build = true,
	["build-server"] = true,
	clean = true,
	ef = true,
	format = true,
	list = true,
	msbuild = true,
	new = true,
	nuget = true,
	pack = true,
	publish = true,
	remove = true,
	restore = true,
	run = true,
	sln = true,
	test = true,
	tool = true,
	watch = true,
}

local TOOLING = {
	"vbcscompiler",
	"msbuild.dll",
	"microsoft.codeanalysis.languageserver",
	"omnisharp",
	"csharplanguageserver",
	"csharp-ls",
	"netcoredbg",
	"dotnet-watch",
}

local function is_tooling(cmdline)
	local verb = cmdline:match("dotnet%s+([%a%-]+)")
	if verb and SDK_VERBS[verb] then
		return true
	end
	for _, name in ipairs(TOOLING) do
		if cmdline:find(name, 1, true) then
			return true
		end
	end
	return false
end

-- Filter for the attach picker. `dotnet run` starts the app through its own
-- executable (bin/Debug/net10.0/App), whose command line does not mention
-- "dotnet" at all, so processes are matched against the assembly names of the
-- workspace's runnable projects (or of `project` alone when given). Anything
-- else hosted by the dotnet executable ("dotnet Other.dll") stays available,
-- minus the tooling. A process that merely mentions dotnet in its arguments
-- (a grep, an editor) is not a candidate.
-- Kept public: pure matching, worth exercising on its own.
function M.attach_filter(project)
	local names = {}
	local candidates = project and { project } or runnable_projects()
	for _, p in ipairs(candidates) do
		names[(assembly_name(p) or project_label(p)):lower()] = true
	end
	return function(proc)
		local cmdline = (proc.name or ""):lower()
		if is_tooling(cmdline) then
			return false
		end
		local executable = true
		for token in cmdline:gmatch("%S+") do
			local base = (token:match("[^/\\]+$") or token):gsub("%.dll$", ""):gsub("%.exe$", "")
			if names[base] or (executable and base == "dotnet") then
				return true
			end
			executable = false
		end
		return false
	end
end

-- Attach config: pick a live process (e.g. the one left by :CsRun / :CsWatch),
-- or attach straight to `pid` when the caller already knows it.
function M.attach_configuration(project, cfg, pid)
	cfg = cfg or dap_config()
	return {
		type = "coreclr",
		name = "dotnetkit: attach",
		request = "attach",
		justMyCode = cfg.just_my_code ~= false,
		processId = pid or function()
			return require("dap.utils").pick_process({
				prompt = "Attach to process:",
				filter = M.attach_filter(project),
			})
		end,
	}
end

-- Provider entry: offered by dap.continue(). One launch entry per runnable
-- project (so dap's own picker selects the project when the cursor is outside
-- them), plus an attach entry. Gated to cs buffers: the old
-- dap.configurations.cs was filetype-scoped and the provider API is not.
function M.configurations(bufnr)
	bufnr = bufnr or 0
	if vim.bo[bufnr].filetype ~= "cs" then
		return {}
	end
	local cfg = dap_config()
	local current = reference.current_project()
	if current then
		current = dotnet.normalize(current)
	end
	local ordered = projects.order_first(runnable_projects(), current)
	local configs = {}
	if #ordered == 0 then
		table.insert(configs, M.launch_configuration(nil, cfg))
	else
		for _, p in ipairs(ordered) do
			table.insert(configs, M.launch_configuration(p, cfg))
		end
	end
	local hint = #ordered == 1 and ordered[1] or nil
	table.insert(configs, M.attach_configuration(hint, cfg))
	return configs
end

-- Any listener keyed with something containing "dapui" (the conventional name
-- is "dapui_config", but the exact key is up to the user's config) counts as
-- "the user already wired dap-ui themselves". Our own key is excluded.
local function has_dapui_listener(listeners)
	for key in pairs(listeners or {}) do
		if type(key) == "string" and key ~= "csnew_dapui" and key:lower():find("dapui", 1, true) then
			return true
		end
	end
	return false
end

local function user_wired_dapui(dap)
	local l = dap.listeners
	return has_dapui_listener(l.after.event_initialized)
		or has_dapui_listener(l.before.event_terminated)
		or has_dapui_listener(l.before.event_exited)
end

-- True when dap-ui already has layouts (i.e. setup() ran). Fails safe to true
-- so a broken probe degrades to "don't call setup()" == today's behavior; the
-- plugin can never clobber the user's dap-ui config.
local function dapui_configured()
	local ok, windows = pcall(require, "dapui.windows")
	if not ok or type(windows) ~= "table" then
		return true
	end
	local layouts = windows.layouts
	if type(layouts) ~= "table" then
		return true
	end
	return #layouts > 0
end

-- dap-ui is only required here, when a real session starts, so registering the
-- listeners never loads dap-ui + nio on .cs startup.
-- Layout used only when dotnetkit is the one calling dapui.setup(). It drops
-- the "console" element, which stays empty with netcoredbg (it has no
-- runInTerminal support, so program output goes to the repl), and gives scopes
-- the room the breakpoint list does not need.
local default_ui_layout = {
	{
		elements = {
			{ id = "scopes", size = 0.35 },
			{ id = "stacks", size = 0.25 },
			{ id = "watches", size = 0.25 },
			{ id = "breakpoints", size = 0.15 },
		},
		size = 40,
		position = "left",
	},
	{
		elements = { "repl" },
		size = 10,
		position = "bottom",
	},
}

local function open_ui()
	local ok, dapui = pcall(require, "dapui")
	if not ok then
		return
	end
	if not dapui_configured() then
		-- Fall back to dap-ui's own defaults if the layout is ever rejected, so a
		-- schema change there cannot leave the UI unconfigured and silent.
		if not pcall(dapui.setup, { layouts = vim.deepcopy(default_ui_layout) }) then
			pcall(dapui.setup)
		end
	end
	dapui.open()
end

local function close_ui()
	local ok, dapui = pcall(require, "dapui")
	if ok then
		dapui.close()
	end
end

local function wire_dapui(dap, cfg)
	if cfg.ui == false then
		return
	end
	if user_wired_dapui(dap) then
		return
	end
	dap.listeners.after.event_initialized["csnew_dapui"] = open_ui
	dap.listeners.before.event_terminated["csnew_dapui"] = close_ui
	dap.listeners.before.event_exited["csnew_dapui"] = close_ui
end

local function wire_keymaps(cfg)
	local prefix = cfg.keymaps
	if not prefix or prefix == false then
		return
	end
	local function map(suffix, fn, desc, mode)
		vim.keymap.set(mode or "n", prefix .. suffix, fn, { silent = true, desc = desc })
	end
	map("b", function()
		require("dap").toggle_breakpoint()
	end, "Debug: toggle breakpoint")
	map("B", function()
		require("dap").set_breakpoint(vim.fn.input("Breakpoint condition: "))
	end, "Debug: conditional breakpoint")
	map("d", function()
		require("dap").clear_breakpoints()
	end, "Debug: clear breakpoints")
	map("l", function()
		require("dap").list_breakpoints()
		vim.cmd("copen")
	end, "Debug: list breakpoints")
	map("c", function()
		require("dap").continue()
	end, "Debug: continue")
	map("o", function()
		require("dap").step_over()
	end, "Debug: step over")
	map("i", function()
		require("dap").step_into()
	end, "Debug: step into")
	map("O", function()
		require("dap").step_out()
	end, "Debug: step out")
	map("t", function()
		require("dap").terminate()
	end, "Debug: terminate")
	-- normal mode evaluates the word under the cursor, visual the selection
	map("e", function()
		local ok, dapui = pcall(require, "dapui")
		if ok then
			dapui.eval()
		end
	end, "Debug: evaluate expression", { "n", "v" })
	map("u", function()
		local ok, dapui = pcall(require, "dapui")
		if ok then
			dapui.toggle()
		end
	end, "Debug: toggle UI")
	map("r", function()
		M.debug_run()
	end, "Debug: run project")
	map("R", function()
		M.debug_attach()
	end, "Debug: attach to process")
end

-- Register the adapter, the config provider and the dap-ui wiring. Idempotent.
-- Requires nvim-dap to be loaded; never forces the load itself.
function M.register()
	if vim.g.csnew_dap_loaded then
		return
	end
	local ok, dap = pcall(require, "dap")
	if not ok then
		return
	end
	local cfg = dap_config()
	-- A coreclr adapter that is already there belongs to the user (or to
	-- another plugin) and is left alone; the configurations below run on it.
	if dap.adapters.coreclr == nil then
		-- Adapter as a function: netcoredbg is resolved when a session actually
		-- starts, so installing it mid-session (e.g. with Mason) needs no restart.
		dap.adapters.coreclr = function(cb)
			local dbg = M.netcoredbg_path()
			if not dbg then
				vim.notify("dotnetkit: netcoredbg not found (:MasonInstall netcoredbg)", vim.log.levels.ERROR)
				return
			end
			cb({
				type = "executable",
				command = dbg,
				args = { "--interpreter=vscode" },
			})
		end
		own_adapter = true
	end
	dap.providers.configs["dotnetkit"] = function(bufnr)
		return M.configurations(bufnr)
	end
	wire_dapui(dap, cfg)
	vim.g.csnew_dap_loaded = true
end

-- Load nvim-dap (an explicit user action) and make sure it is registered.
-- Returns the dap module, or nil (with a notification) when unavailable.
function M.ensure()
	local ok, dap = pcall(require, "dap")
	if not ok then
		vim.notify("dotnetkit: nvim-dap is not installed", vim.log.levels.ERROR)
		return nil
	end
	M.register()
	-- only our adapter needs netcoredbg; someone else's knows its own debugger
	if own_adapter and not M.netcoredbg_path() then
		vim.notify("dotnetkit: netcoredbg not found (:MasonInstall netcoredbg)", vim.log.levels.ERROR)
		return nil
	end
	return dap
end

function M.setup(cfg)
	cfg = cfg or dap_config()
	-- Keymaps are opt-in and registered eagerly so they can trigger the lazy
	-- load of nvim-dap on first press.
	wire_keymaps(cfg)
	-- Only register now if nvim-dap is already loaded; otherwise do not require
	-- it (that would force-load the plugin just from opening a .cs file).
	if package.loaded["dap"] then
		M.register()
		return
	end
	-- Deferred, lazy.nvim-only registration: when nvim-dap eventually loads,
	-- lazy fires User LazyLoad with data == "nvim-dap". Without lazy.nvim this
	-- autocmd simply never fires.
	local group = vim.api.nvim_create_augroup("csnew_dap_lazy", { clear = true })
	vim.api.nvim_create_autocmd("User", {
		group = group,
		pattern = "LazyLoad",
		callback = function(ev)
			if ev.data == "nvim-dap" then
				pcall(vim.api.nvim_del_augroup_by_id, group)
				M.register()
			end
		end,
	})
end

-- Call cb once `session` is no longer nvim-dap's active session. Polls
-- dap.session(), which every nvim-dap version has, and gives up waiting after
-- five seconds so a debugger that ignores terminate cannot block the relaunch.
local function when_session_ends(dap, session, cb)
	local timer = vim.uv.new_timer()
	if not timer then
		cb()
		return
	end
	local waited = 0
	timer:start(
		100,
		100,
		vim.schedule_wrap(function()
			if timer:is_closing() then
				return
			end
			waited = waited + 100
			if dap.session() == session and waited < 5000 then
				return
			end
			timer:stop()
			timer:close()
			cb()
		end)
	)
end

function M.debug_run(opts)
	opts = opts or {}
	local dap = M.ensure()
	if not dap then
		return
	end
	local cfg = dap_config()

	local function launch(project)
		build_project(project, cfg, function(ok)
			if not ok then
				return
			end
			M.with_launch_profile(project, cfg, function(env, args)
				locate_program(project, env, cfg, false, function(dll)
					if dll then
						dap.run(launch_dap_config(project, dll, env, args, cfg))
					end
				end)
			end)
		end)
	end

	run.resolve_runnable("Debug project:", opts.project, function(project)
		project = as_csproj(project)
		-- Running the project that is already being debugged means "restart".
		-- End that session first: otherwise the port check finds our own
		-- debuggee and asks what to do about it.
		local active = dap.session()
		if active and active.config and active.config.name == launch_name(project) then
			dap.terminate()
			when_session_ends(dap, active, function()
				launch(project)
			end)
			return
		end
		launch(project)
	end)
end

-- opts.project restricts the process picker to that project's assembly;
-- opts.pid attaches to a known process without asking.
function M.debug_attach(opts)
	opts = opts or {}
	local dap = M.ensure()
	if not dap then
		return
	end
	local cfg = dap_config()
	local project
	if opts.project and opts.project ~= "" then
		project = as_csproj(dotnet.normalize(opts.project))
	end
	dap.run(M.attach_configuration(project, cfg, opts.pid))
end

function M.debug_stop()
	local dap = package.loaded["dap"]
	if not dap then
		vim.notify("dotnetkit: no active debug session", vim.log.levels.INFO)
		return
	end
	dap.terminate()
end

return M
