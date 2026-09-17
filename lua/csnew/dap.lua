local dotnet = require("csnew.dotnet")
local reference = require("csnew.reference")
local projects = require("csnew.projects")
local run = require("csnew.run")
local build = require("csnew.build")

local M = {}

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

-- Find the built dll for a project (.csproj path or directory), honoring
-- dap.configuration (default "Debug") and RID-specific output folders.
local function find_dll(project, configuration)
	configuration = configuration or dap_config().configuration or "Debug"
	local dir = project_dir(project)
	local name = vim.fn.isdirectory(project) == 1 and vim.fn.fnamemodify(project, ":t:r")
		or assembly_name(project)
	local base = dir .. "/bin/" .. configuration
	-- bin/<cfg>/<tfm>/<name>.dll
	local matches = vim.fn.glob(base .. "/*/" .. name .. ".dll", false, true)
	if #matches > 0 then
		return M.pick_newest_tfm(matches)
	end
	-- bin/<cfg>/<tfm>/<rid>/<name>.dll (RID-specific builds)
	matches = vim.fn.glob(base .. "/*/*/" .. name .. ".dll", false, true)
	if #matches > 0 then
		return M.pick_newest_tfm(matches)
	end
	-- fall back to any dll under the newest tfm
	matches = vim.fn.glob(base .. "/*/*.dll", false, true)
	if #matches > 0 then
		return M.pick_newest_tfm(matches)
	end
	return M.pick_newest_tfm(vim.fn.glob(base .. "/*/*/*.dll", false, true))
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

-- Non-interactive: the current project if it is runnable, else the only
-- runnable project in the workspace, else nil. Never prompts, so it is safe
-- to call from a dap provider (which runs before the user picks a config).
local function current_runnable_project()
	local current = reference.current_project()
	if current then
		current = dotnet.normalize(current)
		if dotnet.is_runnable(current) then
			return current
		end
	end
	local runnable = runnable_projects()
	if #runnable == 1 then
		return runnable[1]
	end
	return nil
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
			vim.notify("csnew: debug launch cancelled", vim.log.levels.INFO)
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

	local name
	local cmdline = "/proc/" .. pid .. "/cmdline"
	if vim.fn.filereadable(cmdline) == 1 then
		local ok, lines = pcall(vim.fn.readfile, cmdline, "b")
		if ok and lines and lines[1] then
			name = lines[1]:gsub("%z", " "):match("([^/ ]+%.dll)") or lines[1]:gsub("%z.*", "")
		end
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
	vim.notify("csnew: pid " .. pid .. " ignored SIGTERM, forcing", vim.log.levels.WARN)
	signal("-KILL")
	return gone(2000)
end

-- Kestrel reports a taken port as an unhandled AddressInUseException in the
-- middle of a debug session, which reads like a crash. Check first and offer
-- the two things you actually want: attach to what is already there, or
-- replace it. Disable with dap.port_check = false.
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
			M.debug_attach()
		elseif choice == "Kill it and launch" then
			if free_port(pid, busy.host, busy.port) then
				cb(true)
			else
				vim.notify("csnew: port " .. busy.port .. " is still in use", vim.log.levels.ERROR)
			end
		elseif choice == "Launch anyway" then
			cb(true)
		end
	end)
end

local function launch_dap_config(project, dll, env, args, cfg)
	local config = {
		type = "coreclr",
		name = "dotnetkit: launch " .. vim.fn.fnamemodify(project, ":t:r"),
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
function M.launch_configuration(project, cfg)
	cfg = cfg or dap_config()
	local label = project and vim.fn.fnamemodify(project, ":t:r") or nil
	local config = {
		type = "coreclr",
		name = "dotnetkit: launch" .. (label and (" " .. label) or ""),
		request = "launch",
		program = function()
			if project then
				local dll = find_dll(project, cfg.configuration)
				if dll then
					return dll
				end
			end
			local dll = M.resolve_dll(project)
			if not dll or dll == "" then
				return require("dap").ABORT
			end
			return dll
		end,
		stopAtEntry = cfg.stop_at_entry or false,
		justMyCode = cfg.just_my_code ~= false,
	}
	if project then
		config.cwd = project_dir(project)
		local env, args = auto_profile(project, cfg)
		if env and next(env) then
			config.env = env
		end
		if args and #args > 0 then
			config.args = args
		end
	end
	return config
end

-- Attach config: pick a live process (e.g. the one left by :CsRun / :CsWatch),
-- filtered to dotnet / this project's assembly name.
function M.attach_configuration(project, cfg)
	cfg = cfg or dap_config()
	local hint = project and vim.fn.fnamemodify(project, ":t:r"):lower() or nil
	return {
		type = "coreclr",
		name = "dotnetkit: attach",
		request = "attach",
		justMyCode = cfg.just_my_code ~= false,
		processId = function()
			return require("dap.utils").pick_process({
				prompt = "Attach to process:",
				filter = function(proc)
					local n = (proc.name or ""):lower()
					if n:find("dotnet", 1, true) then
						return true
					end
					if hint and n:find(hint, 1, true) then
						return true
					end
					return false
				end,
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
	-- Adapter as a function: netcoredbg is resolved when a session actually
	-- starts, so installing it mid-session (e.g. with Mason) needs no restart.
	dap.adapters.coreclr = function(cb)
		local dbg = M.netcoredbg_path()
		if not dbg then
			vim.notify("csnew: netcoredbg not found (:MasonInstall netcoredbg)", vim.log.levels.ERROR)
			return
		end
		cb({
			type = "executable",
			command = dbg,
			args = { "--interpreter=vscode" },
		})
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
		vim.notify("csnew: nvim-dap is not installed", vim.log.levels.ERROR)
		return nil
	end
	M.register()
	if not M.netcoredbg_path() then
		vim.notify("csnew: netcoredbg not found (:MasonInstall netcoredbg)", vim.log.levels.ERROR)
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

function M.debug_run(opts)
	opts = opts or {}
	local dap = M.ensure()
	if not dap then
		return
	end
	local cfg = dap_config()

	local function start(project, env, args)
		local dll = find_dll(project, cfg.configuration)
		if not dll then
			vim.notify(
				"csnew: no " .. (cfg.configuration or "Debug") .. " dll found, build the project first",
				vim.log.levels.ERROR
			)
			return
		end
		check_ports(env, cfg, function()
			dap.run(launch_dap_config(project, dll, env, args, cfg))
		end)
	end

	local function launch(project)
		local function after_build(ok)
			if not ok then
				return -- build.run already opened quickfix and notified
			end
			M.with_launch_profile(project, cfg, function(env, args)
				start(project, env, args)
			end)
		end
		if cfg.build == false then
			after_build(true)
		else
			build.run({ target = project, on_done = after_build })
		end
	end

	run.resolve_runnable("Debug project:", opts.project, launch)
end

function M.debug_attach(opts)
	opts = opts or {}
	local dap = M.ensure()
	if not dap then
		return
	end
	local cfg = dap_config()
	local project = current_runnable_project()
	if opts.project and opts.project ~= "" then
		project = dotnet.normalize(opts.project)
	end
	dap.run(M.attach_configuration(project, cfg))
end

function M.debug_stop()
	local dap = package.loaded["dap"]
	if not dap then
		vim.notify("csnew: no active debug session", vim.log.levels.INFO)
		return
	end
	dap.terminate()
end

return M
