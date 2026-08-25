local dotnet = require("csnew.dotnet")
local namespace = require("csnew.namespace")
local create = require("csnew.create")

local M = {}

function M.current_project()
	return namespace.find_csproj(create.resolve_dir())
end

function M.add(opts)
	opts = opts or {}

	local target = opts.project or M.current_project()
	if not target then
		vim.notify("csnew: no .csproj found for current file", vim.log.levels.ERROR)
		return
	end
	target = dotnet.normalize(target)

	if opts.reference and opts.reference ~= "" then
		local reference = dotnet.normalize(opts.reference)
		if vim.fn.filereadable(reference) ~= 1 then
			vim.notify("csnew: project not found " .. reference, vim.log.levels.ERROR)
			return
		end
		dotnet.run({ "add", target, "reference", reference }, function(ok)
			if ok then
				dotnet.post_change_with_solution()
			end
		end, { success_msg = "csnew: added reference " .. vim.fn.fnamemodify(reference, ":t") })
		return
	end

	local existing = {}
	for _, ref in ipairs(dotnet.csproj_references(target)) do
		existing[ref] = true
	end

	local candidates = {}
	for _, path in ipairs(dotnet.find_projects(dotnet.workspace_root())) do
		if path ~= target and not existing[path] then
			table.insert(candidates, path)
		end
	end

	if #candidates == 0 then
		vim.notify("csnew: no projects available to reference", vim.log.levels.WARN)
		return
	end

	vim.ui.select(candidates, {
		prompt = "Add reference to " .. vim.fn.fnamemodify(target, ":t:r") .. ":",
		format_item = function(p)
			return dotnet.relative_display(p)
		end,
	}, function(choice)
		if choice then
			dotnet.run({ "add", target, "reference", choice }, function(ok)
				if ok then
					dotnet.post_change_with_solution()
				end
			end, { success_msg = "csnew: added reference " .. vim.fn.fnamemodify(choice, ":t") })
		end
	end)
end

function M.remove(opts)
	opts = opts or {}

	local target = opts.project or M.current_project()
	if not target then
		vim.notify("csnew: no .csproj found for current file", vim.log.levels.ERROR)
		return
	end
	target = dotnet.normalize(target)

	local refs = dotnet.csproj_references(target)
	if #refs == 0 then
		vim.notify("csnew: no references to remove", vim.log.levels.WARN)
		return
	end

	if opts.reference and opts.reference ~= "" then
		local reference = dotnet.normalize(opts.reference)
		dotnet.run({ "remove", target, "reference", reference }, function(ok)
			if ok then
				dotnet.post_change_with_solution()
			end
		end, { success_msg = "csnew: removed reference " .. vim.fn.fnamemodify(reference, ":t") })
		return
	end

	vim.ui.select(refs, {
		prompt = "Remove reference from " .. vim.fn.fnamemodify(target, ":t:r") .. ":",
		format_item = function(p)
			return dotnet.relative_display(p)
		end,
	}, function(choice)
		if choice then
			dotnet.run({ "remove", target, "reference", choice }, function(ok)
				if ok then
					dotnet.post_change_with_solution()
				end
			end, { success_msg = "csnew: removed reference " .. vim.fn.fnamemodify(choice, ":t") })
		end
	end)
end

return M
