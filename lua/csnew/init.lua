local M = {}

local config = {
	dotnet = {
		after_change = { "clean", "restore", "lsp_restart" },
	},
	ef = {},
	dap = {
		ui = "auto", -- "auto" | true | false: manage nvim-dap-ui without clobbering user wiring
		build = true, -- build the project before launching
		profile = true, -- apply launchSettings.json (env + args)
		port_check = true, -- warn before launching if the profile port is taken
		configuration = "Debug", -- bin/<configuration>/...
		keymaps = false, -- or a prefix like "<leader>d" to register the standard set
		stop_at_entry = false,
		just_my_code = true,
	},
}

-- is_list({}) is true, so an empty subtable counts as a list and replaces the
-- whole section instead of merging; that is what makes after_change = {} work.
local function is_list(t)
	if vim.islist then
		return vim.islist(t)
	end
	return vim.tbl_islist(t)
end

local function merge(base, override)
	local out = vim.deepcopy(base)
	for k, v in pairs(override or {}) do
		if type(v) == "table" and type(out[k]) == "table" then
			if is_list(v) then
				out[k] = vim.deepcopy(v)
			else
				out[k] = merge(out[k], v)
			end
		else
			out[k] = type(v) == "table" and vim.deepcopy(v) or v
		end
	end
	return out
end

function M.setup(opts)
	config = merge(config, opts or {})
	require("csnew.snippets").register()
	pcall(function()
		require("csnew.dap").setup(config.dap)
	end)
end

function M.get_config()
	local repo = require("csnew.repoconfig").load()
	return merge(config, repo or {})
end

function M.create(opts)
	require("csnew.ui").start(opts or {})
end

function M.command(cmd_opts)
	local fargs = cmd_opts.fargs or {}
	require("csnew.ui").start({
		kind = fargs[1],
		name = fargs[2],
	})
end

return M
