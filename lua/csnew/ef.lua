local dotnet = require("csnew.dotnet")
local projects = require("csnew.projects")
local ui = require("csnew.ui")

local M = {}

local available = false

local function ef_config()
	return require("csnew").get_config().ef or {}
end

local function ensure_ef(cb)
	if available then
		cb()
		return
	end
	dotnet.run({ "ef", "--version" }, function(ok)
		if ok then
			available = true
			cb()
		else
			vim.notify(
				"csnew: dotnet-ef not available\ninstall with: dotnet tool install --global dotnet-ef\n"
					.. "(the startup project needs Microsoft.EntityFrameworkCore.Design)",
				vim.log.levels.ERROR
			)
		end
	end, { success_msg = false })
end

local function resolve_config_path(value, root)
	if not value or value == "" then
		return nil
	end
	local path = value
	if not path:match("^/") and not path:match("^~") then
		path = root .. "/" .. path
	end
	return dotnet.normalize(path)
end

local function resolve_projects(cb)
	local cfg = ef_config()
	local root = dotnet.workspace_root()

	local project = resolve_config_path(cfg.project, root)
	if project and not projects.path_exists(project) then
		vim.notify("csnew: ef.project not found " .. project, vim.log.levels.ERROR)
		return
	end

	local startup = resolve_config_path(cfg.startup_project, root)
	if startup and not projects.path_exists(startup) then
		vim.notify("csnew: ef.startup_project not found " .. startup, vim.log.levels.ERROR)
		return
	end

	if project and startup then
		cb({ project = project, startup = startup })
		return
	end

	if project or startup then
		local missing_prompt = project and "EF: startup project (--startup-project)"
			or "EF: migrations project (--project)"
		projects.pick_one(missing_prompt, project or startup, function(choice)
			if not choice then
				return
			end
			cb({ project = project or choice, startup = startup or choice })
		end)
		return
	end

	projects.pick_pair(cb, {
		project = "EF: migrations project (--project)",
		startup = "EF: startup project (--startup-project)",
		confirm = "EF: projects",
	})
end

local function ef_args(subcmd, projects, extra)
	local args = { "ef" }
	vim.list_extend(args, subcmd)
	vim.list_extend(args, extra or {})
	table.insert(args, "--no-color")
	local cfg = ef_config()
	if cfg.context and cfg.context ~= "" then
		table.insert(args, "--context")
		table.insert(args, cfg.context)
	end
	table.insert(args, "--project")
	table.insert(args, projects.project)
	table.insert(args, "--startup-project")
	table.insert(args, projects.startup)
	return args
end

local function reload_tree()
	pcall(function()
		require("nvim-tree.api").tree.reload()
	end)
end

function M.migrate(opts)
	opts = opts or {}
	ensure_ef(function()
		resolve_projects(function(projects)
			local function run(name)
				if not name:match("^[%a_][%w_]*$") then
					vim.notify("csnew: invalid migration name", vim.log.levels.ERROR)
					return
				end
				local cfg = ef_config()
				local extra = {}
				if cfg.output_dir and cfg.output_dir ~= "" then
					table.insert(extra, "--output-dir")
					table.insert(extra, cfg.output_dir)
				end
				dotnet.run(ef_args({ "migrations", "add", name }, projects, extra), function(ok)
					if not ok then
						return
					end
					local project_dir = vim.fn.isdirectory(projects.project) == 1
							and projects.project
						or vim.fn.fnamemodify(projects.project, ":h")
					local dir = project_dir .. "/" .. (cfg.output_dir or "Migrations")
					local generated
					for _, f in ipairs(vim.fn.glob(dir .. "/*_" .. name .. ".cs", false, true)) do
						if not f:match("%.Designer%.cs$") then
							generated = f
						end
					end
					if generated then
						vim.cmd.edit(vim.fn.fnameescape(generated))
					end
					reload_tree()
					dotnet.lsp_restart()
				end, {
					progress_msg = "csnew: adding migration " .. name,
					success_msg = "csnew: migration " .. name .. " created",
				})
			end

			if opts.name and opts.name ~= "" then
				run(opts.name)
				return
			end
			vim.ui.input({ prompt = "Migration name: " }, function(name)
				if name and name ~= "" then
					run(name)
				end
			end)
		end)
	end)
end

function M.update(opts)
	opts = opts or {}
	ensure_ef(function()
		resolve_projects(function(projects)
			local function run(target)
				local extra = {}
				if target and target ~= "" then
					table.insert(extra, target)
				end
				dotnet.run(ef_args({ "database", "update" }, projects, extra), nil, {
					progress_msg = "csnew: updating database",
					success_msg = "csnew: database updated",
				})
			end

			if opts.target then
				run(opts.target)
				return
			end
			vim.ui.input({ prompt = "Target migration (empty = latest, 0 = revert all): " }, function(target)
				if target then
					run(target)
				end
			end)
		end)
	end)
end

function M.remove()
	ensure_ef(function()
		resolve_projects(function(projects)
			dotnet.run(ef_args({ "migrations", "remove" }, projects), function(ok)
				if not ok then
					return
				end
				reload_tree()
				dotnet.lsp_restart()
			end, {
				progress_msg = "csnew: removing last migration",
				success_msg = "csnew: last migration removed",
			})
		end)
	end)
end

function M.list()
	ensure_ef(function()
		resolve_projects(function(projects)
			dotnet.run(ef_args({ "migrations", "list" }, projects), function(ok, stdout)
				if ok and stdout then
					ui.open_scratch("ef://migrations", vim.split(stdout, "\n", { trimempty = true }))
				end
			end, {
				progress_msg = "csnew: listing migrations",
				success_msg = false,
			})
		end)
	end)
end

function M.script()
	ensure_ef(function()
		resolve_projects(function(projects)
			local cfg = ef_config()
			local output = resolve_config_path(cfg.script_output, dotnet.workspace_root())
				or (dotnet.workspace_root() .. "/Migrations.sql")
			local dir = vim.fn.fnamemodify(output, ":h")
			if vim.fn.isdirectory(dir) == 0 then
				vim.fn.mkdir(dir, "p")
			end
			local subcmd = { "migrations", "script" }
			if cfg.script_idempotent ~= false then
				table.insert(subcmd, "--idempotent")
			end
			table.insert(subcmd, "-o")
			table.insert(subcmd, output)
			dotnet.run(ef_args(subcmd, projects), function(ok)
				if ok then
					vim.cmd.edit(vim.fn.fnameescape(output))
				end
			end, {
				progress_msg = "csnew: generating SQL script",
				success_msg = "csnew: script written to " .. output,
			})
		end)
	end)
end

return M
