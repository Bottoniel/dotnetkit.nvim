local M = {}

-- A fresh directory under Neovim's temp dir (removed when Neovim exits).
function M.tmpdir()
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	return vim.uv.fs_realpath(dir)
end

-- Write a file, creating its parent directories. `content` is a string or a
-- list of lines; nil writes an empty file.
function M.write(path, content)
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	if type(content) == "string" then
		content = vim.split(content, "\n", { plain = true })
	end
	vim.fn.writefile(content or {}, path)
	return path
end

function M.csproj(path, properties, sdk)
	local lines = { ('<Project Sdk="%s">'):format(sdk or "Microsoft.NET.Sdk"), "  <PropertyGroup>" }
	for _, property in ipairs(properties or {}) do
		table.insert(lines, "    " .. property)
	end
	vim.list_extend(lines, { "  </PropertyGroup>", "</Project>" })
	return M.write(path, lines)
end

return M
