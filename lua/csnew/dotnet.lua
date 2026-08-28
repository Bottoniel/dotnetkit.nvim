local M = {}

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function normalize(path)
	path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
	path = path:gsub("\\", "/")
	while path:sub(-1) == "/" and path ~= "/" do
		path = path:sub(1, -2)
	end
	return path
end

M.normalize = normalize

function M.run(args, cb, opts)
	if not vim.system then
		vim.notify("csnew: requires neovim 0.10+", vim.log.levels.ERROR)
		return
	end
	opts = opts or {}
	if opts.progress_msg then
		vim.notify(opts.progress_msg, vim.log.levels.INFO)
	end
	vim.system({ "dotnet", unpack(args) }, { text = true }, function(res)
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
					if detail == nil or trim(detail) == "" then
						detail = res.stdout
					end
					vim.notify("csnew: dotnet failed\n" .. trim(detail or ""), vim.log.levels.ERROR)
				end
				if cb then
					cb(false, res.stdout, res.stderr)
				end
			end
		end)
	end)
end

function M.workspace_root()
	local root = vim.fs.root(0, { ".git" })
	if not root then
		root = vim.fn.getcwd()
	end
	return normalize(root)
end

local function excluded(path)
	local p = path:gsub("\\", "/")
	return p:match("/bin/") or p:match("/obj/") or p:match("/node_modules/") or p:match("/artifacts/")
		or p:match("/%.vs/")
end

local function find_files(root, suffixes)
	local found = vim.fs.find(function(name, path)
		if excluded(path .. "/" .. name) then
			return false
		end
		for _, suffix in ipairs(suffixes) do
			if name:sub(-#suffix) == suffix then
				return true
			end
		end
		return false
	end, { path = root, type = "file", full_path = true, limit = math.huge })
	local results = {}
	for _, f in ipairs(found) do
		table.insert(results, normalize(f))
	end
	table.sort(results)
	return results
end

function M.find_projects(root)
	return find_files(root, { ".csproj" })
end

function M.find_solutions(root)
	return find_files(root, { ".sln", ".slnx" })
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
		vim.notify("csnew: no .sln found in " .. M.workspace_root(), vim.log.levels.ERROR)
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

function M.lsp_restart()
	if vim.fn.exists(":LspRestart") == 2 then
		pcall(vim.cmd, "LspRestart")
		return
	end
	local clients = {}
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_get_option_value("filetype", { buf = buf }) == "cs" then
			for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
				if client.name:match("roslyn") or client.name:match("omnisharp") or client.name:match("csharp") then
					clients[client.id] = true
				end
			end
		end
	end
	local ids = {}
	for id in pairs(clients) do
		table.insert(ids, id)
	end
	if #ids > 0 then
		pcall(vim.lsp.stop_client, ids)
	end
end

function M.post_change_with_solution(cb)
	local solutions = M.find_solutions(M.workspace_root())
	if #solutions == 0 then
		vim.notify("csnew: no .sln found, skipping clean/restore", vim.log.levels.WARN)
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

function M.post_change(sln_path, cb)
	local config = require("csnew").get_config()
	local steps = (config.dotnet and config.dotnet.after_change) or { "clean", "restore", "lsp_restart" }
	local name = vim.fn.fnamemodify(sln_path, ":t")

	local function finish(ok)
		if ok then
			vim.notify("csnew: done", vim.log.levels.INFO)
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
		if s == "clean" then
			M.run({ "clean", sln_path }, function(ok)
				if not ok then
					finish(false)
				else
					step(i + 1)
				end
			end, { progress_msg = "csnew: cleaning " .. name })
		elseif s == "restore" then
			M.run({ "restore", sln_path }, function(ok)
				if not ok then
					finish(false)
				else
					step(i + 1)
				end
			end, { progress_msg = "csnew: restoring " .. name })
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
