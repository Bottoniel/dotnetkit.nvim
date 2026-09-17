-- :checkhealth csnew
--
-- Answers one question: "is the debug / build stack correctly covered here?"

local M = {}

-- Find a module without require()ing it. Uses Lua's module searchers, which
-- work with any plugin manager (lazy.nvim registers its own searcher): a plain
-- runtimepath lookup misses plugins that are installed but not yet loaded,
-- because lazy only adds a plugin dir to the rtp when it loads it.
-- Caveat: with lazy.nvim the searcher itself may load the plugin (it calls
-- auto_load before returning the loader), so callers reporting load/config
-- state must snapshot package.loaded BEFORE probing.
local function module_installed(mod)
	if package.loaded[mod] then
		return true
	end
	for _, searcher in ipairs(package.searchers or package.loaders) do
		local ok, loader = pcall(searcher, mod)
		if ok and type(loader) == "function" then
			return true
		end
	end
	return false
end

local function first_line(s)
	return (vim.trim(s or ""):match("[^\r\n]+"))
end

local function last_line(s)
	local last
	for l in (s or ""):gmatch("[^\r\n]+") do
		local t = vim.trim(l)
		if t ~= "" then
			last = t
		end
	end
	return last
end

-- Run a command (blocking is fine inside :checkhealth) and return its output,
-- or nil when the executable is missing or it exits non-zero.
local function run_out(cmd)
	if vim.fn.executable(cmd[1]) ~= 1 then
		return nil
	end
	local ok, out = pcall(vim.fn.system, cmd)
	if not ok or vim.v.shell_error ~= 0 then
		return nil
	end
	return vim.trim(out or "")
end

local function check_nvim(h)
	h.start("dotnetkit: Neovim")
	local v = vim.version()
	if vim.fn.has("nvim-0.10") == 1 then
		h.ok(("Neovim %d.%d.%d (vim.system available)"):format(v.major, v.minor, v.patch))
	else
		h.error("Neovim >= 0.10 required (everything uses vim.system)")
	end
end

local function check_dotnet(h)
	h.start("dotnetkit: .NET tooling")
	local dotnet = first_line(run_out({ "dotnet", "--version" }))
	if dotnet then
		h.ok("dotnet SDK " .. dotnet)
	else
		h.error("dotnet not found on PATH (build / run / debug need it)")
		return
	end
	-- "dotnet ef --version" prints the tool name on line 1 and the version last
	local ef = last_line(run_out({ "dotnet", "ef", "--version" }))
	if ef then
		h.ok("dotnet-ef " .. ef)
	else
		h.warn("dotnet-ef not available (:EfMigrate/:EfUpdate need it): dotnet tool install --global dotnet-ef")
	end
end

local function check_debug(h)
	h.start("dotnetkit: debug stack")
	-- Snapshot first: with lazy.nvim the module probe itself can load the
	-- plugin (its searcher calls auto_load), which would turn "is it loaded /
	-- configured?" into a self-fulfilling answer.
	local dap_was_loaded = package.loaded["dap"] ~= nil
	local windows = package.loaded["dapui.windows"]
	local dapui_was_configured = type(windows) == "table"
		and type(windows.layouts) == "table"
		and #windows.layouts > 0

	local dap_installed = module_installed("dap")
	local dapui_installed = module_installed("dapui")
	local nio_installed = module_installed("nio")

	if dap_installed then
		local state = dap_was_loaded and "loaded" or "lazy: loads on first debug action"
		h.ok("nvim-dap installed (" .. state .. ")")
	else
		h.warn("nvim-dap not installed - :CsDebugRun/:CsDebugAttach need it")
	end

	if dapui_installed then
		if dapui_was_configured then
			h.ok("nvim-dap-ui installed and configured")
		else
			h.ok("nvim-dap-ui installed (dotnetkit calls setup() on first debug unless you wired it)")
		end
	elseif dap_installed then
		h.info("nvim-dap-ui not installed (optional UI; debug still works in the REPL)")
	end

	if nio_installed then
		h.ok("nvim-nio installed")
	elseif dapui_installed then
		h.warn("nvim-nio missing - nvim-dap-ui requires it")
	end

	local dbg = require("csnew.dap").netcoredbg_path()
	if dbg then
		local ver = first_line(run_out({ dbg, "--version" }))
		h.ok("netcoredbg " .. (ver or "(version unavailable)") .. "  [" .. dbg .. "]")
		-- netcoredbg --version always succeeds, so this note is unconditional:
		-- it is the answer to "where did my app output go?"
		h.info("netcoredbg does not implement runInTerminal: app output shows in the dap-ui REPL (:DapToggleRepl), not the 'console' element")
	else
		h.warn("netcoredbg not found (:MasonInstall netcoredbg, or set dap.netcoredbg)")
	end
end

-- Ask the function itself: whatever patched vim.ui.select knows its own
-- source. Returns the plugin directory name, or nil for the built-in.
local function ui_select_provider()
	local info = debug.getinfo(vim.ui.select, "S")
	local src = (info and info.source or ""):gsub("^@", "")
	if src == "" or src:find("vim[/\\]ui%.lua") then
		return nil
	end
	return src:match("([^/\\]+)[/\\]lua[/\\]") or src
end

local function check_extras(h)
	h.start("dotnetkit: snippets & pickers")
	if module_installed("luasnip") then
		h.ok("LuaSnip installed")
	else
		h.info("LuaSnip not installed (snippets cls/iface/rec/... disabled)")
	end

	local provider = ui_select_provider()
	if provider then
		h.ok("vim.ui.select provider: " .. provider)
	else
		h.info("built-in vim.ui.select (dressing.nvim / telescope-ui-select make pickers nicer)")
	end
end

local function check_attach(h)
	h.start("dotnetkit: attach (ptrace)")
	if vim.fn.has("linux") ~= 1 then
		h.info("ptrace_scope check skipped (non-Linux)")
		return
	end
	local f = io.open("/proc/sys/kernel/yama/ptrace_scope", "r")
	if not f then
		h.info("Yama ptrace_scope not present (attach should work)")
		return
	end
	local val = vim.trim(f:read("*a") or "")
	f:close()
	if val == "0" then
		h.ok("ptrace_scope=0")
	else
		-- informational only: netcoredbg attach uses the .NET runtime
		-- diagnostic channel, not ptrace (verified: no ptrace references in
		-- the binary), and ptrace_scope=1 is the Linux/WSL default
		h.info("ptrace_scope=" .. val .. " (does not affect .NET attach through the runtime diagnostic channel)")
	end
end

local function check_repoconfig(h)
	h.start("dotnetkit: per-repo config")
	local root = require("csnew.dotnet").workspace_root()
	local path = root .. "/.csnew.lua"
	if vim.uv.fs_stat(path) then
		h.info(".csnew.lua found at " .. path .. " (evaluated on demand; Neovim asks you to trust it first)")
	else
		h.info("no .csnew.lua at repo root (" .. root .. ") - defaults / setup() apply")
	end
end

function M.check()
	local h = vim.health
	if not h or not h.start then
		return
	end
	check_nvim(h)
	check_dotnet(h)
	check_debug(h)
	check_extras(h)
	check_attach(h)
	check_repoconfig(h)
end

return M
