local dotnet = require("csnew.dotnet")

local M = {}

local function resolve_sln(preset, cb)
	if preset and preset ~= "" then
		cb(dotnet.normalize(preset))
		return
	end
	dotnet.pick_solution(cb)
end

function M.add(opts)
	opts = opts or {}
	resolve_sln(opts.sln, function(sln)
		if opts.project and opts.project ~= "" then
			local project = dotnet.normalize(opts.project)
			if vim.fn.filereadable(project) ~= 1 then
				vim.notify("dotnetkit: project not found " .. project, vim.log.levels.ERROR)
				return
			end
			dotnet.run({ "sln", sln, "add", project }, function(ok)
				if ok then
					dotnet.invalidate_cache()
					dotnet.post_change(sln)
				end
			end, { success_msg = "dotnetkit: added to solution " .. vim.fn.fnamemodify(project, ":t") })
			return
		end

		local present = {}
		for _, p in ipairs(dotnet.sln_projects(sln)) do
			present[dotnet.normalize(p.path)] = true
		end

		local candidates = {}
		for _, path in ipairs(dotnet.find_projects(dotnet.workspace_root())) do
			if not present[path] then
				table.insert(candidates, path)
			end
		end

		if #candidates == 0 then
			vim.notify("dotnetkit: all projects already in solution", vim.log.levels.WARN)
			return
		end

		vim.ui.select(candidates, {
			prompt = "Add project to solution:",
			format_item = function(p)
				return dotnet.relative_display(p)
			end,
		}, function(choice)
			if choice then
				dotnet.run({ "sln", sln, "add", choice }, function(ok)
					if ok then
						dotnet.invalidate_cache()
						dotnet.post_change(sln)
					end
				end, { success_msg = "dotnetkit: added to solution " .. vim.fn.fnamemodify(choice, ":t") })
			end
		end)
	end)
end

function M.remove(opts)
	opts = opts or {}
	resolve_sln(opts.sln, function(sln)
		local current = dotnet.sln_projects(sln)
		if #current == 0 then
			vim.notify("dotnetkit: solution has no projects", vim.log.levels.WARN)
			return
		end

		if opts.project and opts.project ~= "" then
			local project = dotnet.normalize(opts.project)
			dotnet.run({ "sln", sln, "remove", project }, function(ok)
				if ok then
					dotnet.invalidate_cache()
					dotnet.post_change(sln)
				end
			end, { success_msg = "dotnetkit: removed from solution " .. vim.fn.fnamemodify(project, ":t") })
			return
		end

		vim.ui.select(current, {
			prompt = "Remove project from solution:",
			format_item = function(p)
				return p.name .. "  (" .. dotnet.relative_display(p.path) .. ")"
			end,
		}, function(choice)
			if choice then
				dotnet.run({ "sln", sln, "remove", choice.path }, function(ok)
					if ok then
						dotnet.invalidate_cache()
						dotnet.post_change(sln)
					end
				end, { success_msg = "dotnetkit: removed from solution " .. choice.name })
			end
		end)
	end)
end

return M
