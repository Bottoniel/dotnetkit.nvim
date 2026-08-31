local dotnet = require("csnew.dotnet")
local reference = require("csnew.reference")
local projects = require("csnew.projects")
local ui = require("csnew.ui")

local M = {}

function M.parse_csproj_packages(csproj_path)
	local ok, content = pcall(vim.fn.readfile, csproj_path)
	if not ok then
		return {}
	end
	local pkgs = {}
	local seen = {}
	for name in table.concat(content, "\n"):gmatch('<PackageReference[^>]*Include=["\']([^"\']+)["\']') do
		if not seen[name] then
			seen[name] = true
			table.insert(pkgs, name)
		end
	end
	table.sort(pkgs)
	return pkgs
end

function M.parse_list_json(text)
	local ok, data = pcall(vim.json.decode, text or "")
	if not ok or type(data) ~= "table" then
		return {}
	end
	local rows = {}
	for _, project in ipairs(data.projects or {}) do
		for _, fw in ipairs(project.frameworks or {}) do
			for _, pkg in ipairs(fw.topLevelPackages or {}) do
				table.insert(rows, {
					id = pkg.id,
					requested = pkg.requestedVersion or "",
					resolved = pkg.resolvedVersion or "",
					latest = pkg.latestVersion or pkg.resolvedVersion or "",
				})
			end
		end
	end
	return rows
end

local function resolve_target(preset, cb)
	projects.resolve_current_or_pick("Package project:", preset, cb)
end

function M.add(opts)
	opts = opts or {}
	resolve_target(opts.project, function(target)
		if not target then
			return
		end

		local function run_add(name, version)
			local args = { "add", target, "package", name }
			if version and version ~= "" then
				table.insert(args, "--version")
				table.insert(args, version)
			end
			dotnet.run(args, function(ok)
				if ok then
					dotnet.post_change_with_solution()
				end
			end, { success_msg = "csnew: added package " .. name })
		end

		local function ask_version(name)
			if opts.version then
				run_add(name, opts.version)
				return
			end
			vim.ui.input({ prompt = "Version (empty = latest): " }, function(version)
				run_add(name, version)
			end)
		end

		if opts.name and opts.name ~= "" then
			ask_version(opts.name)
			return
		end
		vim.ui.input({ prompt = "Package name: " }, function(name)
			if name and name ~= "" then
				ask_version(name)
			end
		end)
	end)
end

function M.list(opts)
	opts = opts or {}
	resolve_target(opts.project, function(target)
		if not target then
			return
		end
		dotnet.run({ "list", target, "package", "--format", "json" }, function(ok, stdout)
			if not ok then
				return
			end
			local rows = M.parse_list_json(stdout)
			if #rows == 0 then
				vim.notify("csnew: no packages found", vim.log.levels.WARN)
				return
			end
			for _, row in ipairs(rows) do
				row.latest = ""
			end
			local function show()
				local lines = { "Package                          Current    Latest", string.rep("-", 56) }
				for _, row in ipairs(rows) do
					table.insert(
						lines,
						string.format("%-32s %-10s %s", row.id, row.resolved, row.latest ~= row.resolved and row.latest or "")
					)
				end
				ui.open_scratch("csnew://packages", lines)
			end
			dotnet.run({ "list", target, "package", "--outdated", "--format", "json" }, function(ok2, stdout2)
				if not ok2 then
					vim.notify("csnew: could not check for newer versions", vim.log.levels.WARN)
					show()
					return
				end
				local latest_by_id = {}
				for _, row in ipairs(M.parse_list_json(stdout2)) do
					latest_by_id[row.id] = row.latest
				end
				for _, row in ipairs(rows) do
					if latest_by_id[row.id] then
						row.latest = latest_by_id[row.id]
					end
				end
				show()
			end, {
				progress_msg = "csnew: checking for newer versions",
				success_msg = false,
				fail_msg = false,
			})
		end, {
			progress_msg = "csnew: listing packages",
			success_msg = false,
		})
	end)
end

function M.remove(opts)
	opts = opts or {}
	resolve_target(opts.project, function(target)
		if not target then
			return
		end
		local pkgs = M.parse_csproj_packages(target)
		if #pkgs == 0 then
			vim.notify("csnew: no packages to remove", vim.log.levels.WARN)
			return
		end

		local function run(name)
			dotnet.run({ "remove", target, "package", name }, function(ok)
				if ok then
					dotnet.post_change_with_solution()
				end
			end, { success_msg = "csnew: removed package " .. name })
		end

		if opts.name and opts.name ~= "" then
			run(opts.name)
			return
		end
		vim.ui.select(pkgs, { prompt = "Remove package:" }, function(choice)
			if choice then
				run(choice)
			end
		end)
	end)
end

function M.update(opts)
	opts = opts or {}
	resolve_target(opts.project, function(target)
		if not target then
			return
		end

		local function run(name, version)
			local args = { "add", target, "package", name }
			if version and version ~= "" then
				table.insert(args, "--version")
				table.insert(args, version)
			end
			dotnet.run(args, function(ok)
				if ok then
					dotnet.post_change_with_solution()
				end
			end, { success_msg = "csnew: updated package " .. name })
		end

		if opts.name and opts.name ~= "" then
			run(opts.name, opts.version)
			return
		end

		dotnet.run({ "list", target, "package", "--outdated", "--format", "json" }, function(ok, stdout)
			if not ok then
				return
			end
			local outdated = {}
			for _, row in ipairs(M.parse_list_json(stdout)) do
				if row.latest ~= "" and row.latest ~= row.resolved then
					table.insert(outdated, row)
				end
			end
			if #outdated == 0 then
				vim.notify("csnew: all packages are up to date", vim.log.levels.INFO)
				return
			end
			vim.ui.select(outdated, {
				prompt = "Update package:",
				format_item = function(row)
					return row.id .. "  " .. row.resolved .. " -> " .. row.latest
				end,
			}, function(choice)
				if choice then
					run(choice.id, choice.latest)
				end
			end)
		end, {
			progress_msg = "csnew: checking outdated packages",
			success_msg = false,
		})
	end)
end

return M
