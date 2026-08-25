local namespace = require("csnew.namespace")
local templates = require("csnew.templates")

local M = {}

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.resolve_dir()
	if vim.bo.filetype ~= "NvimTree" then
		local file = vim.api.nvim_buf_get_name(0)
		if file ~= "" and vim.bo.buftype == "" then
			return vim.fn.fnamemodify(file, ":p:h")
		end
	end
	return vim.fn.getcwd()
end

function M.type_name(kind, name)
	name = trim(name):gsub("%.cs$", "")
	if kind == "interface" and not name:match("^I%u") then
		name = "I" .. name
	elseif kind == "exception" and not name:match("Exception$") then
		name = name .. "Exception"
	elseif kind == "controller" and not name:match("Controller$") then
		name = name .. "Controller"
	end
	return name
end

function M.create(opts)
	local kind = opts.kind
	local name = M.type_name(kind, opts.name or "")
	local dir = opts.dir or M.resolve_dir()
	local ns = opts.namespace or namespace.from_dir(dir)

	if name == "" or not name:match("^[%a_][%w_]*$") then
		vim.notify("csnew: invalid type name", vim.log.levels.ERROR)
		return
	end
	if not vim.tbl_contains(templates.kinds, kind) then
		vim.notify("csnew: unknown type " .. tostring(kind), vim.log.levels.ERROR)
		return
	end
	if not ns or ns == "" then
		vim.notify("csnew: no .csproj found and no namespace given", vim.log.levels.ERROR)
		return
	end

	local path = vim.fs.joinpath and vim.fs.joinpath(dir, name .. ".cs") or (dir .. "/" .. name .. ".cs")
	if vim.fn.filereadable(path) == 1 then
		vim.notify("csnew: file exists " .. path, vim.log.levels.ERROR)
		return
	end

	local lines, cursor = templates.render(kind, name, ns)
	if not lines then
		return
	end

	if vim.fn.isdirectory(dir) == 0 then
		vim.fn.mkdir(dir, "p")
	end
	vim.fn.writefile(lines, path)

	if vim.bo.filetype == "NvimTree" then
		vim.cmd("wincmd p")
	end
	vim.cmd.edit(vim.fn.fnameescape(path))
	pcall(vim.api.nvim_win_set_cursor, 0, cursor)
	vim.cmd("startinsert")
	pcall(function()
		require("nvim-tree.api").tree.reload()
	end)
end

return M
