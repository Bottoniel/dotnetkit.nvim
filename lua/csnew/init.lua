local M = {}

local config = {
	dotnet = {
		after_change = { "clean", "restore", "lsp_restart" },
	},
	ef = {},
}

function M.setup(opts)
	config = vim.tbl_deep_extend("force", config, opts or {})
	require("csnew.snippets").register()
	pcall(function()
		require("csnew.dap").setup()
	end)
end

function M.get_config()
	local repo = require("csnew.repoconfig").load()
	if repo then
		return vim.tbl_deep_extend("force", config, repo)
	end
	return config
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
