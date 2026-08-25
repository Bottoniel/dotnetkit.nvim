local M = {}

local function normalize_dir(path)
	path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
	if path:sub(-1) == "/" then
		path = path:sub(1, -2)
	end
	return path
end

local function sanitize_part(part)
	part = part:gsub("%-", "_"):gsub("[^%w_]", "_")
	if part:match("^[0-9]") then
		part = "_" .. part
	end
	if part == "" or part == "_" then
		return nil
	end
	return part
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

function M.find_csproj(start_dir)
	local dir = normalize_dir(start_dir)
	if vim.fn.isdirectory(dir) == 0 then
		dir = vim.fn.fnamemodify(dir, ":h")
	end
	while dir and dir ~= "" do
		local found = vim.fn.glob(dir .. "/*.csproj", false, true)
		if #found > 0 then
			return found[1]
		end
		local parent = vim.fn.fnamemodify(dir, ":h")
		if parent == dir then
			break
		end
		dir = parent
	end
	return nil
end

function M.root_namespace(csproj_path)
	local ok, lines = pcall(vim.fn.readfile, csproj_path)
	if ok then
		local root = table.concat(lines, "\n"):match("<RootNamespace>%s*(.-)%s*</RootNamespace>")
		if root and root ~= "" then
			return root
		end
	end
	return vim.fn.fnamemodify(csproj_path, ":t:r")
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
