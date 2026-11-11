local M = {}

local function normalize_dir(path)
	path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
	if path:sub(-1) == "/" then
		path = path:sub(1, -2)
	end
	return path
end

-- Bytes >= 128 are kept: they are the UTF-8 encoding of letters such as "ó",
-- which C# identifiers allow and %w (ASCII only) does not cover.
local function sanitize_part(part)
	part = part:gsub("[^%w_\128-\255]", "_")
	if part:match("^[0-9]") then
		part = "_" .. part
	end
	if part == "" or part == "_" then
		return nil
	end
	return part
end

-- "My-App.Core" -> "My_App.Core": every dotted segment becomes a valid identifier.
local function sanitize_dotted(name)
	local parts = {}
	for part in name:gmatch("[^.]+") do
		local sanitized = sanitize_part(part)
		if sanitized then
			table.insert(parts, sanitized)
		end
	end
	return table.concat(parts, ".")
end

function M.relative(from, to)
	from = normalize_dir(from)
	to = normalize_dir(to)
	if vim.fs.relpath then
		local rel = vim.fs.relpath(from, to)
		if rel == "." then
			return ""
		end
		return rel or ""
	end
	if to == from then
		return ""
	end
	local prefix = from .. "/"
	if to:sub(1, #prefix) == prefix then
		return to:sub(#prefix + 1)
	end
	return ""
end

-- First .csproj (by name) directly inside dir. Reads the directory instead of
-- globbing, so 'wildignore' and paths with [brackets] cannot hide it.
local function csproj_in(dir)
	local found = {}
	local handle = vim.uv.fs_scandir(dir)
	while handle do
		local name, kind = vim.uv.fs_scandir_next(handle)
		if not name then
			break
		end
		if kind ~= "directory" and name:sub(-7) == ".csproj" then
			table.insert(found, name)
		end
	end
	table.sort(found)
	return found[1] and (dir .. "/" .. found[1]) or nil
end

function M.find_csproj(start_dir, stop_at)
	stop_at = normalize_dir(stop_at or require("csnew.dotnet").workspace_root())
	local dir = normalize_dir(start_dir)
	if vim.fn.isdirectory(dir) == 0 then
		dir = vim.fn.fnamemodify(dir, ":h")
	end
	local prefix = stop_at .. "/"
	while dir and dir ~= "" do
		if dir ~= stop_at and dir:sub(1, #prefix) ~= prefix then
			break
		end
		local found = csproj_in(dir)
		if found then
			return found
		end
		if dir == stop_at then
			break
		end
		local parent = vim.fn.fnamemodify(dir, ":h")
		if parent == dir then
			break
		end
		dir = parent
	end
	return nil
end

local function read_csproj(csproj_path)
	local ok, lines = pcall(vim.fn.readfile, csproj_path)
	if not ok then
		return nil
	end
	return table.concat(lines, "\n")
end

function M.root_namespace(csproj_path)
	local content = read_csproj(csproj_path)
	if content then
		local root = content:match("<RootNamespace>%s*(.-)%s*</RootNamespace>")
		-- an MSBuild expression cannot be evaluated here; fall back to the name
		if root and root ~= "" and not root:find("$(", 1, true) then
			return root
		end
	end
	local name = vim.fn.fnamemodify(csproj_path, ":t:r")
	local sanitized = sanitize_dotted(name)
	return sanitized ~= "" and sanitized or name
end

-- The C# version a target framework defaults to.
local function lang_from_tfm(tfm)
	tfm = vim.trim(tfm):lower()
	local major = tonumber(tfm:match("^net(%d+)%.%d"))
	if major then
		-- net5.0 -> C# 9, net6.0 -> 10, net8.0 -> 12, ...
		return major >= 5 and (major + 4) or 7.3
	end
	local core = tonumber(tfm:match("^netcoreapp(%d+)%."))
	if core then
		return core >= 3 and 8 or 7.3
	end
	if tfm:match("^netstandard2%.1") then
		return 8
	end
	if tfm:match("^netstandard") or tfm:match("^net%d") then
		return 7.3 -- .NET Standard 2.0 and .NET Framework (net48, net472, ...)
	end
	return nil
end

-- What the templates need to know about a project:
--   lang            C# version as a number, math.huge for latest/preview, or
--                   nil when the .csproj does not say (e.g. it comes from
--                   Directory.Build.props), in which case callers assume modern
--   implicit_usings whether <ImplicitUsings> is enabled in the .csproj
function M.project_info(csproj_path)
	local content = read_csproj(csproj_path)
	if not content then
		return {}
	end

	local implicit = (content:match("<ImplicitUsings>%s*(.-)%s*</ImplicitUsings>") or ""):lower()
	local info = { implicit_usings = implicit == "enable" or implicit == "true" }

	local explicit = (content:match("<LangVersion>%s*(.-)%s*</LangVersion>") or ""):lower()
	if explicit == "latest" or explicit == "latestmajor" or explicit == "preview" then
		info.lang = math.huge
		return info
	end
	if tonumber(explicit) then
		info.lang = tonumber(explicit)
		return info
	end

	local frameworks = content:match("<TargetFrameworks>%s*(.-)%s*</TargetFrameworks>")
		or content:match("<TargetFramework>%s*(.-)%s*</TargetFramework>")
	if not frameworks then
		return info
	end
	-- multi-targeting: the code has to compile for the oldest target
	for tfm in frameworks:gmatch("[^;]+") do
		local lang = lang_from_tfm(tfm)
		if lang and (not info.lang or lang < info.lang) then
			info.lang = lang
		end
	end
	return info
end

function M.from_dir(dir)
	local csproj = M.find_csproj(dir)
	if not csproj then
		return nil
	end
	local parts = { M.root_namespace(csproj) }
	local rel = M.relative(vim.fn.fnamemodify(csproj, ":h"), dir)
	if rel ~= "" then
		for part in rel:gmatch("[^/\\]+") do
			local sanitized = sanitize_part(part)
			if sanitized then
				table.insert(parts, sanitized)
			end
		end
	end
	return table.concat(parts, ".")
end

return M
