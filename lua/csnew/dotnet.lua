local M = {}

local DEFAULT_AFTER_CHANGE = { "restore", "lsp_restart" }

local function normalize(path)
	path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
	path = path:gsub("\\", "/")
	while path:sub(-1) == "/" and path ~= "/" do
		path = path:sub(1, -2)
	end
	return path
end

M.normalize = normalize

-- Start `dotnet <args>` in the workspace root, so global.json and the local
-- tool manifest (where dotnet-ef often lives) resolve against the repo and not
-- against wherever Neovim happens to be.
-- Returns false, after notifying, when the process could not be started at
-- all; cb is never called in that case.
function M.run(args, cb, opts)
	if not vim.system then
		vim.notify("dotnetkit: requires neovim 0.10+", vim.log.levels.ERROR)
		return false
	end
	opts = opts or {}
	if vim.fn.executable("dotnet") ~= 1 then
		vim.notify("dotnetkit: dotnet not found on PATH", vim.log.levels.ERROR)
		return false
	end
	local ok, err = pcall(
		vim.system,
		{ "dotnet", unpack(args) },
		{ text = true, cwd = opts.cwd or M.workspace_root() },
		function(res)
			vim.schedule(function()
				if res.code == 0 then
					if opts.success_msg ~= false then
						vim.notify(opts.success_msg or ("dotnet " .. table.concat(args, " ")), vim.log.levels.INFO)
					end
					if cb then
						cb(true, res.stdout, res.stderr)
					end
				else
					if opts.fail_msg ~= false then
						local detail = res.stderr
						if detail == nil or vim.trim(detail) == "" then
							detail = res.stdout
						end
						vim.notify("dotnetkit: dotnet failed\n" .. vim.trim(detail or ""), vim.log.levels.ERROR)
					end
					if cb then
						cb(false, res.stdout, res.stderr)
					end
				end
			end)
		end
	)
	if not ok then
		vim.notify("dotnetkit: could not start dotnet\n" .. tostring(err), vim.log.levels.ERROR)
		return false
	end
	if opts.progress_msg then
		vim.notify(opts.progress_msg, vim.log.levels.INFO)
	end
	return true
end

-- The git root of the current buffer's file, or of the cwd for a buffer
-- without one, falling back to the cwd itself.
-- The buffers this plugin opens (the run terminal, the scratch lists) carry
-- the workspace they were opened from in b:csnew_root: the cursor ends up in
-- them, and if Neovim was started outside the repo the cwd would otherwise
-- turn $HOME, or wherever it is, into the workspace for the next command.
function M.workspace_root()
	local remembered = vim.b.csnew_root
	if type(remembered) == "string" and vim.fn.isdirectory(remembered) == 1 then
		return remembered
	end
	return normalize(vim.fs.root(0, { ".git" }) or vim.fn.getcwd())
end

-- Tag a buffer the plugin opened with the workspace it belongs to.
function M.remember_root(buf, root)
	vim.b[buf].csnew_root = root
end

-- Directories that are never descended into. Matched against the directory's
-- own name, below the root, so a repo that itself lives under a folder called
-- "bin" is still scanned.
local SKIP_DIRS = {
	bin = true,
	obj = true,
	node_modules = true,
	artifacts = true,
	[".git"] = true,
	[".vs"] = true,
}

local CACHE_TTL = 5000

-- root -> { at, projects, solutions }
local scan_cache = {}

-- keyed by csproj path, invalidated by the file's own mtime
local runnable_cache = {}

-- One pruned walk collects projects and solutions together.
local function scan(root)
	local now = vim.uv.now()
	local entry = scan_cache[root]
	if entry and (now - entry.at) < CACHE_TTL then
		return entry
	end

	local projects, solutions = {}, {}
	local stack = { root }
	while #stack > 0 do
		local dir = table.remove(stack)
		local handle = vim.uv.fs_scandir(dir)
		while handle do
			local name, kind = vim.uv.fs_scandir_next(handle)
			if not name then
				break
			end
			local path = dir == "/" and ("/" .. name) or (dir .. "/" .. name)
			if kind == nil or kind == "unknown" then
				-- some filesystems do not report the entry type
				local stat = vim.uv.fs_lstat(path)
				kind = stat and stat.type or nil
			end
			if kind == "directory" then
				if not SKIP_DIRS[name] then
					stack[#stack + 1] = path
				end
			elseif kind == "file" then
				if name:sub(-7) == ".csproj" then
					projects[#projects + 1] = path
				elseif name:sub(-4) == ".sln" or name:sub(-5) == ".slnx" then
					solutions[#solutions + 1] = path
				end
			end
		end
	end
	table.sort(projects)
	table.sort(solutions)

	entry = { at = now, projects = projects, solutions = solutions }
	scan_cache[root] = entry
	return entry
end

function M.invalidate_cache()
	scan_cache = {}
	runnable_cache = {}
end

-- results are copied on return so callers cannot mutate the cache
function M.find_projects(root)
	return vim.list_extend({}, scan(root).projects)
end

function M.find_solutions(root)
	return vim.list_extend({}, scan(root).solutions)
end

function M.relative_display(path, root)
	root = root or M.workspace_root()
	local prefix = root .. "/"
	if path:sub(1, #prefix) == prefix then
		return path:sub(#prefix + 1)
	end
	return path
end

function M.pick_solution(cb)
	local solutions = M.find_solutions(M.workspace_root())
	if #solutions == 0 then
		vim.notify("dotnetkit: no .sln found in " .. M.workspace_root(), vim.log.levels.ERROR)
		return
	end
	if #solutions == 1 then
		cb(solutions[1])
		return
	end
	vim.ui.select(solutions, {
		prompt = "Solution:",
		format_item = function(p)
			return vim.fn.fnamemodify(p, ":t") .. "  (" .. M.relative_display(p) .. ")"
		end,
	}, function(choice)
		if choice then
			cb(choice)
		end
	end)
end

function M.sln_projects(sln_path)
	local ok, lines = pcall(vim.fn.readfile, sln_path)
	if not ok then
		return {}
	end
	local projects = {}
	local sln_dir = vim.fn.fnamemodify(sln_path, ":h")

	local function add(rel, name)
		rel = rel:gsub("\\", "/")
		if rel:match("%.csproj$") then
			table.insert(projects, {
				name = name or vim.fn.fnamemodify(rel, ":t:r"),
				path = normalize(sln_dir .. "/" .. rel),
			})
		end
	end

	if sln_path:match("%.slnx$") then
		for rel in table.concat(lines, "\n"):gmatch('<Project[^>]*Path=["\']([^"\']+)["\']') do
			add(rel)
		end
	else
		for _, line in ipairs(lines) do
			local name, rel = line:match('^Project%([^)]*%)%s*=%s*"([^"]+)"%s*,%s*"([^"]+)"')
			if name and rel then
				add(rel, name)
			end
		end
	end
	return projects
end

function M.csproj_references(csproj_path)
	local ok, content = pcall(vim.fn.readfile, csproj_path)
	if not ok then
		return {}
	end
	local dir = vim.fn.fnamemodify(csproj_path, ":h")
	local refs = {}
	for rel in table.concat(content, "\n"):gmatch('<ProjectReference[^>]*Include=["\']([^"\']+)["\']') do
		table.insert(refs, normalize(dir .. "/" .. rel:gsub("\\", "/")))
	end
	return refs
end

function M.is_runnable(csproj_path)
	local stat = vim.uv.fs_stat(csproj_path)
	if not stat then
		runnable_cache[csproj_path] = nil
		return false
	end

	local entry = runnable_cache[csproj_path]
	if entry and entry.sec == stat.mtime.sec and entry.nsec == stat.mtime.nsec then
		return entry.value
	end

	local ok, lines = pcall(vim.fn.readfile, csproj_path)
	if not ok then
		return false
	end
	local content = table.concat(lines, "\n")
	local value = false
	if content:match('<Project[^>]*Sdk=["\'][^"\']*Microsoft%.NET%.Sdk%.Web') then
		value = true
	elseif content:match('<Project[^>]*Sdk=["\'][^"\']*Microsoft%.NET%.Sdk%.Worker') then
		value = true
	else
		local out = content:match("<OutputType>%s*(.-)%s*</OutputType>")
		value = out ~= nil and out:lower() == "exe"
	end
	runnable_cache[csproj_path] = { sec = stat.mtime.sec, nsec = stat.mtime.nsec, value = value }
	return value
end

local function is_csharp_client(client)
	local name = (client.name or ""):lower()
	return name:find("roslyn", 1, true) ~= nil
		or name:find("omnisharp", 1, true) ~= nil
		or name:find("csharp", 1, true) ~= nil
end

-- Last resort when neither `:lsp restart` nor `:LspRestart` exists: stop the
-- client and, once it is gone, re-fire FileType on its buffers so whatever
-- started it in the first place attaches a fresh one.
local function restart_by_refiring_filetype(client)
	local bufs = {}
	for buf in pairs(client.attached_buffers or {}) do
		table.insert(bufs, buf)
	end
	client:stop()

	local timer = vim.uv.new_timer()
	if not timer then
		return
	end
	local tries = 0
	timer:start(
		100,
		100,
		vim.schedule_wrap(function()
			if timer:is_closing() then
				return
			end
			tries = tries + 1
			if not client:is_stopped() and tries < 50 then
				return
			end
			timer:stop()
			timer:close()
			for _, buf in ipairs(bufs) do
				if vim.api.nvim_buf_is_loaded(buf) then
					vim.bo[buf].filetype = vim.bo[buf].filetype
				end
			end
		end)
	)
end

-- Restart the C# language servers, and only those: a bare :LspRestart takes
-- every other server down with it.
function M.lsp_restart()
	local names, seen, clients = {}, {}, {}
	for _, client in ipairs(vim.lsp.get_clients()) do
		if is_csharp_client(client) then
			table.insert(clients, client)
			if not seen[client.name] then
				seen[client.name] = true
				table.insert(names, client.name)
			end
		end
	end
	if #clients == 0 then
		return
	end

	local command
	if vim.fn.exists(":lsp") == 2 then
		command = "lsp restart " -- Neovim 0.12+
	elseif vim.fn.exists(":LspRestart") == 2 then
		command = "LspRestart " -- nvim-lspconfig
	end
	if command then
		for _, name in ipairs(names) do
			pcall(vim.cmd, command .. name)
		end
		return
	end

	for _, client in ipairs(clients) do
		pcall(restart_by_refiring_filetype, client)
	end
end

local function after_change_steps()
	local config = require("csnew").get_config()
	return (config.dotnet and config.dotnet.after_change) or DEFAULT_AFTER_CHANGE
end

-- True when the user's after_change list includes the step, so the commands
-- that only want an LSP restart honor the same setting.
function M.after_change_has(step)
	return vim.tbl_contains(after_change_steps(), step)
end

function M.post_change_with_solution(cb)
	local solutions = M.find_solutions(M.workspace_root())
	if #solutions == 0 then
		vim.notify("dotnetkit: no .sln found, skipping restore", vim.log.levels.WARN)
		if cb then
			cb(false)
		end
		return
	end
	local function run(sln)
		M.post_change(sln, cb)
	end
	if #solutions == 1 then
		run(solutions[1])
		return
	end
	vim.ui.select(solutions, {
		prompt = "Solution:",
		format_item = function(p)
			return vim.fn.fnamemodify(p, ":t") .. "  (" .. M.relative_display(p) .. ")"
		end,
	}, function(choice)
		if choice then
			run(choice)
		elseif cb then
			cb(false)
		end
	end)
end

local STEP_COMMANDS = {
	clean = { verb = "clean", label = "cleaning" },
	restore = { verb = "restore", label = "restoring" },
}

function M.post_change(sln_path, cb)
	local steps = after_change_steps()
	local name = vim.fn.fnamemodify(sln_path, ":t")
	local ran = false

	local function finish(ok)
		if ok and ran then
			vim.notify("dotnetkit: " .. name .. " is up to date", vim.log.levels.INFO)
		end
		if cb then
			cb(ok)
		end
	end

	local function step(i)
		if i > #steps then
			finish(true)
			return
		end
		local s = steps[i]
		local command = STEP_COMMANDS[s]
		if command then
			ran = true
			local started = M.run({ command.verb, sln_path }, function(ok)
				if not ok then
					finish(false)
				else
					step(i + 1)
				end
			end, { progress_msg = "dotnetkit: " .. command.label .. " " .. name, success_msg = false })
			if not started then
				finish(false)
			end
		elseif s == "lsp_restart" then
			M.lsp_restart()
			step(i + 1)
		else
			step(i + 1)
		end
	end

	step(1)
end

return M
