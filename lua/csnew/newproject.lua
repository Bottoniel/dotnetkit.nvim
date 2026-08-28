local dotnet = require("csnew.dotnet")

local M = {}

M.templates = { "console", "classlib", "webapi", "web", "xunit", "nunit", "mstest" }

local function reload_tree()
	pcall(function()
		require("nvim-tree.api").tree.reload()
	end)
end

local function maybe_add_to_sln(project_path)
	local solutions = dotnet.find_solutions(dotnet.workspace_root())
	if #solutions == 0 then
		reload_tree()
		return
	end
	local function add(sln)
		dotnet.run({ "sln", sln, "add", project_path }, function()
			reload_tree()
		end, { success_msg = "csnew: added to solution " .. vim.fn.fnamemodify(project_path, ":t") })
	end
	vim.ui.select({ "Yes", "No" }, { prompt = "Add to solution?" }, function(choice)
		if choice ~= "Yes" then
			reload_tree()
			return
		end
		if #solutions == 1 then
			add(solutions[1])
			return
		end
		dotnet.pick_solution(add)
	end)
end

function M.create(opts)
	opts = opts or {}

	local function run(template, name, outdir)
		if not name or name == "" or not name:match("^[%a_][%w_.%-]*$") then
			vim.notify("csnew: invalid project name", vim.log.levels.ERROR)
			return
		end
		outdir = outdir ~= "" and outdir or ("src/" .. name)
		if not outdir:match("^/") then
			outdir = dotnet.workspace_root() .. "/" .. outdir
		end
		outdir = dotnet.normalize(outdir)
		dotnet.run({ "new", template, "-n", name, "-o", outdir }, function(ok)
			if not ok then
				return
			end
			dotnet.invalidate_cache()
			local csproj = outdir .. "/" .. name .. ".csproj"
			if vim.fn.filereadable(csproj) ~= 1 then
				local found = vim.fn.glob(outdir .. "/*.csproj", false, true)
				csproj = found[1]
			end
			if csproj then
				maybe_add_to_sln(dotnet.normalize(csproj))
			else
				reload_tree()
			end
		end, { success_msg = "csnew: created " .. template .. " " .. name })
	end

	local function ask_outdir(template, name)
		if opts.outdir then
			run(template, name, opts.outdir)
			return
		end
		vim.ui.input({ prompt = "Output dir: ", default = "src/" .. name }, function(outdir)
			if outdir then
				run(template, name, outdir)
			end
		end)
	end

	local function ask_name(template)
		if opts.name and opts.name ~= "" then
			ask_outdir(template, opts.name)
			return
		end
		vim.ui.input({ prompt = "Project name: " }, function(name)
			if name and name ~= "" then
				ask_outdir(template, name)
			end
		end)
	end

	if opts.template and opts.template ~= "" then
		ask_name(opts.template)
		return
	end
	vim.ui.select(M.templates, { prompt = "dotnet new template:" }, function(template)
		if template then
			ask_name(template)
		end
	end)
end

return M
