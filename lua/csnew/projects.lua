local dotnet = require("csnew.dotnet")
local reference = require("csnew.reference")

local M = {}

local last_selection = {}

function M.path_exists(path)
	return vim.fn.filereadable(path) == 1 or vim.fn.isdirectory(path) == 1
end

function M.order_first(candidates, first)
	if not first or not vim.tbl_contains(candidates, first) then
		return candidates
	end
	local out = { first }
	for _, c in ipairs(candidates) do
		if c ~= first then
			table.insert(out, c)
		end
	end
	return out
end

function M.pick_one(prompt, prefer, cb)
	local root = dotnet.workspace_root()
	local candidates = dotnet.find_projects(root)
	if #candidates == 0 then
		vim.notify("dotnetkit: no .csproj found in " .. root, vim.log.levels.ERROR)
		return
	end
	if #candidates == 1 then
		cb(candidates[1])
		return
	end
	vim.ui.select(M.order_first(candidates, prefer or reference.current_project()), {
		prompt = prompt or "Project:",
		format_item = function(p)
			return dotnet.relative_display(p, root)
		end,
	}, cb)
end

function M.pick_pair(cb, labels)
	labels = labels or {}
	local root = dotnet.workspace_root()
	local candidates = dotnet.find_projects(root)
	if #candidates == 0 then
		vim.notify("dotnetkit: no .csproj found in " .. root, vim.log.levels.ERROR)
		return
	end
	if #candidates == 1 then
		cb({ project = candidates[1], startup = candidates[1] })
		return
	end

	local function do_pick()
		vim.ui.select(M.order_first(candidates, reference.current_project()), {
			prompt = labels.project or "Project:",
			format_item = function(p)
				return dotnet.relative_display(p, root)
			end,
		}, function(project)
			if not project then
				return
			end
			vim.ui.select(M.order_first(candidates, project), {
				prompt = labels.startup or "Startup project:",
				format_item = function(p)
					return dotnet.relative_display(p, root)
				end,
			}, function(startup)
				if not startup then
					return
				end
				last_selection[root] = { project = project, startup = startup }
				cb({ project = project, startup = startup })
			end)
		end)
	end

	local last = last_selection[root]
	if not last or not M.path_exists(last.project) or not M.path_exists(last.startup) then
		do_pick()
		return
	end
	vim.ui.select({
		"Use last: "
			.. dotnet.relative_display(last.project, root)
			.. " -> "
			.. dotnet.relative_display(last.startup, root),
		"Pick other projects",
	}, { prompt = labels.confirm or "Projects:" }, function(choice)
		if not choice then
			return
		end
		if choice:match("^Use last") then
			cb({ project = last.project, startup = last.startup })
		else
			do_pick()
		end
	end)
end

function M.resolve_current_or_pick(prompt, preset, cb)
	if preset and preset ~= "" then
		cb(dotnet.normalize(preset))
		return
	end
	local current = reference.current_project()
	if current then
		cb(dotnet.normalize(current))
		return
	end
	M.pick_one(prompt or "Project:", nil, cb)
end

return M
