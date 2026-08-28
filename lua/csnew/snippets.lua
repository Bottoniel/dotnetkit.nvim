local M = {}

local autocmd_id

local prefixes = {
	{ trig = "cls", kind = "class", desc = "class + namespace" },
	{ trig = "iface", kind = "interface", desc = "interface + namespace" },
	{ trig = "rec", kind = "record", desc = "record + namespace" },
	{ trig = "enm", kind = "enum", desc = "enum + namespace" },
	{ trig = "ctrl", kind = "controller", desc = "controller + namespace" },
	{ trig = "exc", kind = "exception", desc = "exception + namespace" },
}

local function context(kind)
	local create = require("csnew.create")
	local namespace = require("csnew.namespace")
	local raw = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t:r")
	local name = create.type_name(kind, raw)
	if name == "" or not name:match("^[%a_][%w_]*$") then
		name = create.type_name(kind, "Name")
	end
	local dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":h")
	return name, namespace.from_dir(dir) or "Namespace"
end

function M.register()
	if vim.g.csnew_snippets_loaded then
		return
	end
	local ok, ls = pcall(require, "luasnip")
	if not ok then
		if not autocmd_id then
			local group = vim.api.nvim_create_augroup("CsnewSnippets", { clear = true })
			autocmd_id = vim.api.nvim_create_autocmd("FileType", {
				group = group,
				pattern = "cs",
				callback = function()
					M.register()
				end,
			})
		end
		return
	end

	local templates = require("csnew.templates")
	local s = ls.snippet
	local i = ls.insert_node
	local f = ls.function_node
	local snippets = {}

	for _, spec in ipairs(prefixes) do
		snippets[#snippets + 1] = s({ trig = spec.trig, name = spec.desc, desc = spec.desc }, {
			f(function()
				local name, ns = context(spec.kind)
				return select(1, templates.split_at_cursor(spec.kind, name, ns))
			end, {}),
			i(0),
			f(function()
				local name, ns = context(spec.kind)
				return select(2, templates.split_at_cursor(spec.kind, name, ns))
			end, {}),
		})
	end

	ls.add_snippets("cs", snippets, { key = "csnew" })
	if autocmd_id then
		pcall(vim.api.nvim_del_autocmd, autocmd_id)
		autocmd_id = nil
	end
	vim.g.csnew_snippets_loaded = true
end

return M
