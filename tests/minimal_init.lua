-- Minimal init for the test suite: this plugin plus plenary.nvim, nothing else.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/?.lua;" .. package.path -- require("tests.helpers")

local plenary = vim.env.PLENARY_DIR
if not plenary or plenary == "" then
	for _, candidate in ipairs({
		vim.fn.stdpath("data") .. "/lazy/plenary.nvim",
		vim.fn.stdpath("data") .. "/site/pack/packer/start/plenary.nvim",
		vim.fn.stdpath("data") .. "/site/pack/core/opt/plenary.nvim",
	}) do
		if vim.fn.isdirectory(candidate) == 1 then
			plenary = candidate
			break
		end
	end
end
if not plenary or vim.fn.isdirectory(plenary) == 0 then
	error("plenary.nvim not found: set PLENARY_DIR to its directory")
end
vim.opt.rtp:prepend(plenary)

vim.o.swapfile = false
vim.cmd("runtime plugin/plenary.vim")
vim.cmd("runtime plugin/csnew.lua")
