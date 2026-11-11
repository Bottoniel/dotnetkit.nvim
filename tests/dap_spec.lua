local h = require("tests.helpers")
local dap = require("csnew.dap")
local dotnet = require("csnew.dotnet")

-- resolve_dll asks for a path when nothing is found; answer with a marker.
local ASKED = "<asked for the path>"

describe("dll resolution", function()
	local input

	before_each(function()
		input = vim.fn.input
		vim.fn.input = function()
			return ASKED
		end
	end)

	after_each(function()
		vim.fn.input = input
		vim.o.wildignore = ""
	end)

	local function project(properties)
		local root = h.tmpdir()
		return h.csproj(root .. "/App.csproj", properties or { "<OutputType>Exe</OutputType>" }), root
	end

	it("finds bin/<configuration>/<tfm>/<assembly>.dll", function()
		local csproj, root = project()
		h.write(root .. "/bin/Debug/net10.0/App.dll")
		h.write(root .. "/bin/Release/net10.0/App.dll")

		assert.are.same(root .. "/bin/Debug/net10.0/App.dll", dap.resolve_dll(csproj))
	end)

	it("finds it no matter what 'wildignore' hides", function()
		local csproj, root = project()
		h.write(root .. "/bin/Debug/net10.0/App.dll")

		for _, ignore in ipairs({ "*.dll,*.exe", "*/bin/*,*/obj/*" }) do
			vim.o.wildignore = ignore
			assert.are.same(root .. "/bin/Debug/net10.0/App.dll", dap.resolve_dll(csproj), ignore)
		end
	end)

	it("prefers the newest target framework", function()
		local csproj, root = project()
		for _, tfm in ipairs({ "net8.0", "net10.0", "net9.0", "netstandard2.0" }) do
			h.write(root .. "/bin/Debug/" .. tfm .. "/App.dll")
		end

		assert.are.same(root .. "/bin/Debug/net10.0/App.dll", dap.resolve_dll(csproj))
	end)

	it("looks into runtime-specific folders", function()
		local csproj, root = project()
		h.write(root .. "/bin/Debug/net10.0/linux-x64/App.dll")

		assert.are.same(root .. "/bin/Debug/net10.0/linux-x64/App.dll", dap.resolve_dll(csproj))
	end)

	it("honors AssemblyName", function()
		local csproj, root = project({ "<AssemblyName>Shop.Host</AssemblyName>" })
		h.write(root .. "/bin/Debug/net10.0/App.dll")
		h.write(root .. "/bin/Debug/net10.0/Shop.Host.dll")

		assert.are.same(root .. "/bin/Debug/net10.0/Shop.Host.dll", dap.resolve_dll(csproj))
	end)

	it("falls back to the assembly with a runtimeconfig, never to a dependency", function()
		local csproj, root = project({ "<AssemblyName>$(Company).App</AssemblyName>" })
		local out = root .. "/bin/Debug/net10.0/"
		for _, file in ipairs({ "AutoMapper.dll", "Contoso.App.dll", "Contoso.App.runtimeconfig.json", "Zeta.dll" }) do
			h.write(out .. file)
		end

		assert.are.same(out .. "Contoso.App.dll", dap.resolve_dll(csproj))
	end)

	it("asks instead of guessing when only dependencies are there", function()
		local csproj, root = project({ "<AssemblyName>$(Company).App</AssemblyName>" })
		h.write(root .. "/bin/Debug/net10.0/AutoMapper.dll")

		assert.are.same(ASKED, dap.resolve_dll(csproj))
	end)

	it("accepts the project directory, dots in its name included", function()
		local root = h.tmpdir() .. "/Shop.Api"
		h.csproj(root .. "/Shop.Api.csproj", {}, "Microsoft.NET.Sdk.Web")
		h.write(root .. "/bin/Debug/net10.0/Shop.Api.dll")

		assert.are.same(root .. "/bin/Debug/net10.0/Shop.Api.dll", dap.resolve_dll(root))
	end)
end)

describe("dap.pick_newest_tfm", function()
	it("orders frameworks numerically, not alphabetically", function()
		assert.are.same(
			"/p/bin/Debug/net10.0/A.dll",
			dap.pick_newest_tfm({ "/p/bin/Debug/net9.0/A.dll", "/p/bin/Debug/net10.0/A.dll", "/p/bin/Debug/net8.0/A.dll" })
		)
		assert.is_nil(dap.pick_newest_tfm({}))
	end)
end)

describe("dap.profile_endpoints", function()
	it("extracts host and port from ASPNETCORE_URLS", function()
		local endpoints = dap.profile_endpoints({
			ASPNETCORE_URLS = "https://localhost:7260;http://localhost:5252;http://*:8080;http://[::1]:5001;http://localhost",
		})

		assert.are.same({
			{ url = "https://localhost:7260", host = "127.0.0.1", port = 7260 },
			{ url = "http://localhost:5252", host = "127.0.0.1", port = 5252 },
			{ url = "http://*:8080", host = "127.0.0.1", port = 8080 },
			{ url = "http://[::1]:5001", host = "::1", port = 5001 },
		}, endpoints)
		assert.are.same({}, dap.profile_endpoints({}))
		assert.are.same({}, dap.profile_endpoints(nil))
	end)
end)

describe("dap.port_listening", function()
	it("tells a listening port from a free one", function()
		local server = assert(vim.uv.new_tcp())
		server:bind("127.0.0.1", 0)
		server:listen(1, function() end)
		local port = server:getsockname().port

		assert.is_true(dap.port_listening("127.0.0.1", port))
		server:close()
		vim.wait(50)
		assert.is_false(dap.port_listening("127.0.0.1", port))
	end)
end)

describe("the attach picker", function()
	local function workspace()
		local root = h.tmpdir()
		h.csproj(root .. "/src/Shop.Api/Shop.Api.csproj", {}, "Microsoft.NET.Sdk.Web")
		h.csproj(root .. "/src/Worker/Worker.csproj", { "<AssemblyName>shop-worker</AssemblyName>" }, "Microsoft.NET.Sdk.Worker")
		h.csproj(root .. "/src/Core/Core.csproj")
		return root
	end

	local function filter_in(root, project)
		local workspace_root = dotnet.workspace_root
		dotnet.workspace_root = function()
			return root
		end
		dotnet.invalidate_cache()
		local filter = dap.attach_filter(project)
		dotnet.workspace_root = workspace_root
		return function(cmdline)
			return filter({ pid = 1, name = cmdline })
		end
	end

	it("offers the apps of the workspace, however they were started", function()
		local offered = filter_in(workspace())

		-- `dotnet run` starts the app through its own executable
		assert.is_true(offered("/home/u/shop/src/Shop.Api/bin/Debug/net10.0/Shop.Api"))
		assert.is_true(offered("/usr/lib/dotnet/dotnet /home/u/shop/src/Shop.Api/bin/Debug/net10.0/Shop.Api.dll"))
		assert.is_true(offered("/home/u/shop/src/Worker/bin/Debug/net10.0/shop-worker --verbose"))
		assert.is_true(offered("C:\\shop\\src\\Shop.Api\\bin\\Debug\\net10.0\\Shop.Api.exe"))
	end)

	it("keeps other dotnet-hosted processes available", function()
		local offered = filter_in(workspace())

		assert.is_true(offered("dotnet /srv/other/Other.dll"))
		assert.is_true(offered("dotnet exec /srv/other/Other.dll"))
	end)

	it("leaves out the dotnet CLI, build servers and language servers", function()
		local offered = filter_in(workspace())

		assert.is_false(offered("dotnet run --project src/Shop.Api"))
		assert.is_false(offered("dotnet watch --project src/Shop.Api run"))
		assert.is_false(offered("dotnet build"))
		assert.is_false(offered("/usr/lib/dotnet/sdk/10.0.114/Roslyn/bincore/VBCSCompiler -pipename:x"))
		assert.is_false(offered("/usr/lib/dotnet/dotnet /usr/lib/dotnet/sdk/10.0.114/MSBuild.dll /nodeReuse:true"))
		assert.is_false(offered("/usr/lib/dotnet/dotnet /x/Microsoft.CodeAnalysis.LanguageServer.dll --logLevel=Information"))
		assert.is_false(offered("/home/u/.local/share/nvim/mason/bin/netcoredbg --interpreter=vscode"))
	end)

	it("leaves out everything unrelated", function()
		local offered = filter_in(workspace())

		assert.is_false(offered("/usr/bin/zsh"))
		assert.is_false(offered("nvim src/Shop.Api/Program.cs"))
		assert.is_false(offered("/home/u/shop/src/Core/bin/Debug/net10.0/Core"))
	end)

	it("is not fooled by processes that only mention dotnet", function()
		local offered = filter_in(workspace())

		assert.is_false(offered("grep -r dotnet /var/log"))
		assert.is_false(offered("nvim /home/u/notes/dotnet.md"))
		assert.is_false(offered("/home/u/dotnet-tools/bin/something --serve"))
	end)

	it("can be narrowed to one project", function()
		local root = workspace()
		local offered = filter_in(root, root .. "/src/Worker/Worker.csproj")

		assert.is_true(offered("/home/u/shop/src/Worker/bin/Debug/net10.0/shop-worker"))
		assert.is_false(offered("/home/u/shop/src/Shop.Api/bin/Debug/net10.0/Shop.Api"))
	end)
end)

describe("dap configurations", function()
	it("attaches straight to a known pid, and asks otherwise", function()
		assert.are.same(4242, dap.attach_configuration(nil, {}, 4242).processId)
		assert.are.same("function", type(dap.attach_configuration(nil, {}).processId))
	end)

	it("names launch configurations after the project", function()
		local csproj = h.csproj(h.tmpdir() .. "/Shop.Api/Shop.Api.csproj", {}, "Microsoft.NET.Sdk.Web")
		local config = dap.launch_configuration(csproj, { profile = false })

		assert.are.same("dotnetkit: launch Shop.Api", config.name)
		assert.are.same("coreclr", config.type)
		assert.are.same(vim.fn.fnamemodify(csproj, ":h"), config.cwd)
		assert.is_true(config.justMyCode)
		assert.is_false(config.stopAtEntry)
	end)

	it("applies the only launch profile without asking", function()
		local root = h.tmpdir()
		local csproj = h.csproj(root .. "/Api.csproj", {}, "Microsoft.NET.Sdk.Web")
		h.write(root .. "/Properties/launchSettings.json", {
			'{ "profiles": { "http": { "commandName": "Project", "applicationUrl": "http://localhost:5252",',
			'  "commandLineArgs": "--seed" } } }',
		})

		local config = dap.launch_configuration(csproj, {})

		assert.are.same({ ASPNETCORE_URLS = "http://localhost:5252" }, config.env)
		assert.are.same({ "--seed" }, config.args)
	end)
end)
