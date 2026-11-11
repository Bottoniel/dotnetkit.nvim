local h = require("tests.helpers")
local dotnet = require("csnew.dotnet")

local function relative(paths, root)
	return vim.tbl_map(function(p)
		return dotnet.relative_display(p, root)
	end, paths)
end

describe("project discovery", function()
	before_each(function()
		dotnet.invalidate_cache()
	end)

	it("finds projects and solutions, sorted, in one tree", function()
		local root = h.tmpdir()
		h.csproj(root .. "/src/Web/Web.csproj")
		h.csproj(root .. "/src/Core/Core.csproj")
		h.csproj(root .. "/tests/Core.Tests/Core.Tests.csproj")
		h.write(root .. "/App.sln")
		h.write(root .. "/other/Other.slnx")

		assert.are.same(
			{ "src/Core/Core.csproj", "src/Web/Web.csproj", "tests/Core.Tests/Core.Tests.csproj" },
			relative(dotnet.find_projects(root), root)
		)
		assert.are.same({ "App.sln", "other/Other.slnx" }, relative(dotnet.find_solutions(root), root))
	end)

	it("does not descend into build output, dependencies or .git", function()
		local root = h.tmpdir()
		h.csproj(root .. "/src/App/App.csproj")
		for _, skipped in ipairs({ "bin", "obj", "node_modules", "artifacts", ".git", ".vs" }) do
			h.csproj(root .. "/src/App/" .. skipped .. "/Hidden/Hidden.csproj")
		end

		assert.are.same({ "src/App/App.csproj" }, relative(dotnet.find_projects(root), root))
	end)

	it("still scans a repo that lives under a directory called bin", function()
		local root = h.tmpdir() .. "/bin/artifacts/repo"
		h.csproj(root .. "/App/App.csproj")
		h.write(root .. "/App.sln")

		assert.are.same({ "App/App.csproj" }, relative(dotnet.find_projects(root), root))
		assert.are.same({ "App.sln" }, relative(dotnet.find_solutions(root), root))
	end)

	it("returns copies, so callers cannot corrupt the cache", function()
		local root = h.tmpdir()
		h.csproj(root .. "/App/App.csproj")

		table.insert(dotnet.find_projects(root), "junk")
		assert.are.same(1, #dotnet.find_projects(root))
	end)
end)

describe("workspace_root", function()
	local cwd

	before_each(function()
		cwd = vim.fn.getcwd()
	end)

	after_each(function()
		vim.cmd.cd(vim.fn.fnameescape(cwd))
	end)

	local function repo_with_file()
		local repo = h.tmpdir()
		vim.fn.mkdir(repo .. "/.git", "p")
		return repo, h.write(repo .. "/src/App/Program.cs")
	end

	it("is the git root of the current file, wherever Neovim was started", function()
		local repo, file = repo_with_file()
		vim.cmd.cd(vim.fn.fnameescape(h.tmpdir()))

		vim.cmd.edit(vim.fn.fnameescape(file))

		assert.are.same(repo, dotnet.workspace_root())
	end)

	it("is kept by the scratch buffers the plugin opens", function()
		local repo, file = repo_with_file()
		vim.cmd.cd(vim.fn.fnameescape(h.tmpdir())) -- Neovim started outside the repo
		vim.cmd.edit(vim.fn.fnameescape(file))

		require("csnew.ui").open_scratch("csnew://test-" .. vim.fn.fnamemodify(repo, ":t"), { "line" })

		assert.are.same("nofile", vim.bo.buftype)
		assert.are.same(repo, dotnet.workspace_root())
	end)

	it("is the cwd when there is no repository at all", function()
		local dir = h.tmpdir()
		vim.cmd.cd(vim.fn.fnameescape(dir))

		vim.cmd.edit(vim.fn.fnameescape(h.write(dir .. "/Loose.cs")))
		assert.are.same(dir, dotnet.workspace_root())

		vim.cmd.enew()
		assert.are.same(dir, dotnet.workspace_root())
	end)
end)

describe("solution and project files", function()
	it("reads the projects of a .sln", function()
		local root = h.tmpdir()
		h.write(root .. "/App.sln", {
			"Microsoft Visual Studio Solution File, Format Version 12.00",
			'Project("{FAE04EC0-301F-11D3-BF4B-00C04F79EFBC}") = "Web", "src\\Web\\Web.csproj", "{1}"',
			"EndProject",
			'Project("{2150E333-8FDC-42A3-9474-1A3956D46DE8}") = "src", "src", "{2}"',
			"EndProject",
		})

		assert.are.same(
			{ { name = "Web", path = root .. "/src/Web/Web.csproj" } },
			dotnet.sln_projects(root .. "/App.sln")
		)
	end)

	it("reads the projects of a .slnx", function()
		local root = h.tmpdir()
		h.write(root .. "/App.slnx", {
			"<Solution>",
			'  <Folder Name="/src/">',
			'    <Project Path="src/Api/Api.csproj" />',
			"  </Folder>",
			"</Solution>",
		})

		assert.are.same(
			{ { name = "Api", path = root .. "/src/Api/Api.csproj" } },
			dotnet.sln_projects(root .. "/App.slnx")
		)
	end)

	it("resolves ProjectReference paths relative to the project", function()
		local root = h.tmpdir()
		h.write(root .. "/src/Web/Web.csproj", {
			'<Project Sdk="Microsoft.NET.Sdk.Web">',
			'  <ItemGroup><ProjectReference Include="..\\Core\\Core.csproj" /></ItemGroup>',
			"</Project>",
		})

		assert.are.same({ root .. "/src/Core/Core.csproj" }, dotnet.csproj_references(root .. "/src/Web/Web.csproj"))
	end)

	it("knows which projects can be launched", function()
		local root = h.tmpdir()
		local exe = h.csproj(root .. "/Exe.csproj", { "<OutputType>Exe</OutputType>" })
		local web = h.csproj(root .. "/Web.csproj", {}, "Microsoft.NET.Sdk.Web")
		local worker = h.csproj(root .. "/Worker.csproj", {}, "Microsoft.NET.Sdk.Worker")
		local lib = h.csproj(root .. "/Lib.csproj")

		assert.is_true(dotnet.is_runnable(exe))
		assert.is_true(dotnet.is_runnable(web))
		assert.is_true(dotnet.is_runnable(worker))
		assert.is_false(dotnet.is_runnable(lib))
		assert.is_false(dotnet.is_runnable(root .. "/Missing.csproj"))
	end)
end)

describe("dotnet.run", function()
	it("reports a missing dotnet instead of throwing, and never calls back", function()
		local path = vim.env.PATH
		local notify = vim.notify
		local messages, called = {}, false
		vim.env.PATH = h.tmpdir()
		vim.notify = function(msg)
			table.insert(messages, msg)
		end

		local ok, started = pcall(dotnet.run, { "--version" }, function()
			called = true
		end)

		vim.env.PATH = path
		vim.notify = notify
		assert.is_true(ok)
		assert.is_false(started)
		assert.is_false(called)
		assert.are.same({ "dotnetkit: dotnet not found on PATH" }, messages)
	end)
end)

describe("lsp_restart", function()
	local function fake_server(starts, name)
		return function(dispatchers)
			starts[name] = (starts[name] or 0) + 1
			local closing = false
			return {
				request = function(method, _, callback)
					if method == "initialize" then
						callback(nil, { capabilities = {} })
					elseif method == "shutdown" then
						callback(nil, nil)
					end
					return true, 1
				end,
				notify = function(method)
					if method == "exit" then
						closing = true
						dispatchers.on_exit(0, 0)
					end
					return true
				end,
				is_closing = function()
					return closing
				end,
				terminate = function()
					closing = true
					dispatchers.on_exit(0, 15)
				end,
			}
		end
	end

	it("restarts the C# server and leaves every other server running", function()
		local starts = {}
		local group = vim.api.nvim_create_augroup("csnew_test_lsp", { clear = true })
		-- stands in for whatever autostarts servers (vim.lsp.enable, lspconfig)
		vim.api.nvim_create_autocmd("FileType", {
			group = group,
			pattern = "cs",
			callback = function(ev)
				vim.lsp.start({ name = "roslyn", cmd = fake_server(starts, "roslyn") }, { bufnr = ev.buf })
				vim.lsp.start({ name = "lua_ls", cmd = fake_server(starts, "lua_ls") }, { bufnr = ev.buf })
			end,
		})
		local buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".cs")
		vim.api.nvim_set_current_buf(buf)
		vim.bo[buf].filetype = "cs"
		vim.wait(1000, function()
			return #vim.lsp.get_clients({ bufnr = buf }) == 2
		end)
		local other = vim.lsp.get_clients({ name = "lua_ls" })[1]
		local old = vim.lsp.get_clients({ name = "roslyn" })[1]

		dotnet.lsp_restart()
		vim.wait(3000, function()
			local current = vim.lsp.get_clients({ bufnr = buf, name = "roslyn" })[1]
			return current ~= nil and current.id ~= old.id
		end, 20)

		local current = vim.lsp.get_clients({ bufnr = buf, name = "roslyn" })[1]
		assert.is_not_nil(current)
		assert.are_not.equal(old.id, current.id)
		assert.are.same(2, starts.roslyn)
		assert.are.same(1, starts.lua_ls)
		assert.are.same(other.id, vim.lsp.get_clients({ name = "lua_ls" })[1].id)

		vim.api.nvim_del_augroup_by_id(group)
		for _, client in ipairs(vim.lsp.get_clients()) do
			client:stop(true)
		end
	end)
end)
