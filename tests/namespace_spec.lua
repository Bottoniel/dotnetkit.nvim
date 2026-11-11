local h = require("tests.helpers")
local dotnet = require("csnew.dotnet")
local namespace = require("csnew.namespace")

-- from_dir stops at the workspace root; pin that to the test's directory.
local function from_dir(root, dir)
	local workspace_root = dotnet.workspace_root
	dotnet.workspace_root = function()
		return root
	end
	local result = namespace.from_dir(dir)
	dotnet.workspace_root = workspace_root
	return result
end

describe("namespace inference", function()
	it("is the project name plus the folders below it", function()
		local root = h.tmpdir()
		h.csproj(root .. "/src/Shop.Api/Shop.Api.csproj")
		vim.fn.mkdir(root .. "/src/Shop.Api/Features/Orders", "p")

		assert.are.same("Shop.Api", from_dir(root, root .. "/src/Shop.Api"))
		assert.are.same("Shop.Api.Features.Orders", from_dir(root, root .. "/src/Shop.Api/Features/Orders"))
	end)

	it("prefers an explicit RootNamespace", function()
		local root = h.tmpdir()
		h.csproj(root .. "/Api/Api.csproj", { "<RootNamespace>Contoso.Shop</RootNamespace>" })
		vim.fn.mkdir(root .. "/Api/Models", "p")

		assert.are.same("Contoso.Shop.Models", from_dir(root, root .. "/Api/Models"))
	end)

	it("falls back to the project name when RootNamespace is an MSBuild expression", function()
		local root = h.tmpdir()
		h.csproj(root .. "/Api/Api.csproj", { "<RootNamespace>$(Company).Api</RootNamespace>" })

		assert.are.same("Api", from_dir(root, root .. "/Api"))
	end)

	it("turns a project name into valid identifiers", function()
		local root = h.tmpdir()
		h.csproj(root .. "/a/My-App.csproj")
		h.csproj(root .. "/b/My App.Core.csproj")
		h.csproj(root .. "/c/3D.Engine.csproj")

		assert.are.same("My_App", from_dir(root, root .. "/a"))
		assert.are.same("My_App.Core", from_dir(root, root .. "/b"))
		assert.are.same("_3D.Engine", from_dir(root, root .. "/c"))
	end)

	it("sanitizes folder names but keeps non-ASCII letters", function()
		local root = h.tmpdir()
		h.csproj(root .. "/Lib/Lib.csproj")
		vim.fn.mkdir(root .. "/Lib/Configuración/data-access/2fa", "p")

		assert.are.same(
			"Lib.Configuración.data_access._2fa",
			from_dir(root, root .. "/Lib/Configuración/data-access/2fa")
		)
	end)

	it("finds the project through directories with glob characters", function()
		local root = h.tmpdir()
		h.csproj(root .. "/we[i]rd/Lib.csproj")
		vim.fn.mkdir(root .. "/we[i]rd/Models", "p")

		assert.are.same(root .. "/we[i]rd/Lib.csproj", namespace.find_csproj(root .. "/we[i]rd/Models", root))
	end)

	it("is not affected by 'wildignore'", function()
		local root = h.tmpdir()
		h.csproj(root .. "/Lib/Lib.csproj")
		vim.o.wildignore = "*.csproj"

		local found = namespace.find_csproj(root .. "/Lib", root)

		vim.o.wildignore = ""
		assert.are.same(root .. "/Lib/Lib.csproj", found)
	end)

	it("does not look above the workspace root", function()
		local root = h.tmpdir()
		h.csproj(root .. "/Outer.csproj")
		vim.fn.mkdir(root .. "/repo/src", "p")

		assert.is_nil(namespace.find_csproj(root .. "/repo/src", root .. "/repo"))
	end)
end)

describe("project_info", function()
	local function info(properties)
		return namespace.project_info(h.csproj(h.tmpdir() .. "/P.csproj", properties))
	end

	it("derives the C# version from the target framework", function()
		local cases = {
			["net10.0"] = 14,
			["net8.0"] = 12,
			["net8.0-windows"] = 12,
			["net6.0"] = 10,
			["net5.0"] = 9,
			["netcoreapp3.1"] = 8,
			["netcoreapp2.1"] = 7.3,
			["netstandard2.1"] = 8,
			["netstandard2.0"] = 7.3,
			["net48"] = 7.3,
			["net472"] = 7.3,
		}
		for tfm, lang in pairs(cases) do
			assert.are.same(lang, info({ "<TargetFramework>" .. tfm .. "</TargetFramework>" }).lang, tfm)
		end
	end)

	it("uses the oldest target when multi-targeting", function()
		assert.are.same(7.3, info({ "<TargetFrameworks>net8.0;netstandard2.0</TargetFrameworks>" }).lang)
	end)

	it("lets an explicit LangVersion win", function()
		local tfm = "<TargetFramework>netstandard2.0</TargetFramework>"
		assert.are.same(11, info({ tfm, "<LangVersion>11.0</LangVersion>" }).lang)
		assert.are.same(math.huge, info({ tfm, "<LangVersion>latest</LangVersion>" }).lang)
		assert.are.same(math.huge, info({ tfm, "<LangVersion>preview</LangVersion>" }).lang)
		assert.are.same(7.3, info({ tfm, "<LangVersion>default</LangVersion>" }).lang)
	end)

	it("leaves the version unknown when the project does not state a target", function()
		assert.is_nil(info({}).lang)
		assert.is_nil(info({ "<TargetFramework>$(Tfm)</TargetFramework>" }).lang)
	end)

	it("reports implicit usings", function()
		assert.is_true(info({ "<ImplicitUsings>enable</ImplicitUsings>" }).implicit_usings)
		assert.is_true(info({ "<ImplicitUsings>true</ImplicitUsings>" }).implicit_usings)
		assert.is_false(info({ "<ImplicitUsings>disable</ImplicitUsings>" }).implicit_usings)
		assert.is_false(info({}).implicit_usings)
	end)
end)
