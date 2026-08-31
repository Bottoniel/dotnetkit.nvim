local create = require("csnew.create")
local namespace = require("csnew.namespace")
local templates = require("csnew.templates")

local M = {}

local function ask_namespace(dir, cb)
	local inferred = namespace.from_dir(dir)
	if inferred then
		cb(inferred)
		return
	end
	vim.ui.input({ prompt = "Namespace: " }, function(ns)
		if ns and ns ~= "" then
			cb(ns)
		end
	end)
end

local function ask_name(kind, preset, cb)
	if preset and preset ~= "" then
		cb(preset)
		return
	end
	vim.ui.input({ prompt = "Name (" .. kind .. "): " }, function(name)
		if name and name ~= "" then
			cb(name)
		end
	end)
end

local function ask_kind(preset, cb)
	if preset and preset ~= "" then
		if not vim.tbl_contains(templates.kinds, preset) then
			vim.notify("csnew: unknown type " .. preset, vim.log.levels.ERROR)
			return
		end
		cb(preset)
		return
	end
	vim.ui.select(templates.kinds, { prompt = "C# type" }, function(kind)
		if kind then
			cb(kind)
		end
	end)
end

function M.start(opts)
	opts = opts or {}
	local dir = opts.dir or create.resolve_dir()

	ask_kind(opts.kind, function(kind)
		ask_name(kind, opts.name, function(name)
			ask_namespace(dir, function(ns)
				create.create({
					dir = dir,
					kind = kind,
					name = name,
					namespace = ns,
				})
			end)
		end)
	end)
end

function M.open_scratch(name, lines)
	local buf = -1
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == name then
			buf = b
			break
		end
	end
	if buf == -1 then
		buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, name)
		vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
		vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
		vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
	end
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	vim.api.nvim_set_option_value("filetype", "text", { buf = buf })
	local win
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_buf(w) == buf then
			win = w
			break
		end
	end
	if win then
		vim.api.nvim_set_current_win(win)
		return
	end
	vim.cmd("sbuffer " .. buf)
end

return M
