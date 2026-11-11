local h = require("tests.helpers")
local dotnet = require("csnew.dotnet")
local package_ = require("csnew.package")

describe("package parsing", function()
	it("lists the PackageReferences of a project once each, sorted", function()
		local csproj = h.write(h.tmpdir() .. "/App.csproj", {
			'<Project Sdk="Microsoft.NET.Sdk">',
			"  <ItemGroup>",
			'    <PackageReference Include="Serilog" Version="4.0.0" />',
			'    <PackageReference Include="Dapper" Version="2.1.0" />',
			"    <PackageReference Include='Serilog' />",
			"  </ItemGroup>",
			"</Project>",
		})

		assert.are.same({ "Dapper", "Serilog" }, package_.parse_csproj_packages(csproj))
	end)

	it("reads `dotnet list package --format json`", function()
		local rows = package_.parse_list_json(vim.json.encode({
			projects = {
				{
					frameworks = {
						{
							topLevelPackages = {
								{ id = "Dapper", requestedVersion = "2.1.0", resolvedVersion = "2.1.0", latestVersion = "2.1.35" },
								{ id = "Serilog", requestedVersion = "4.0.0", resolvedVersion = "4.0.0" },
							},
						},
					},
				},
			},
		}))

		assert.are.same({
			{ id = "Dapper", requested = "2.1.0", resolved = "2.1.0", latest = "2.1.35" },
			{ id = "Serilog", requested = "4.0.0", resolved = "4.0.0", latest = "4.0.0" },
		}, rows)
		assert.are.same({}, package_.parse_list_json("not json"))
		assert.are.same({}, package_.parse_list_json(nil))
	end)
end)

describe("package.add", function()
	local run, input, calls

	before_each(function()
		run, input, calls = dotnet.run, vim.ui.input, {}
		dotnet.run = function(args)
			table.insert(calls, table.concat(args, " "))
			return true
		end
	end)

	after_each(function()
		dotnet.run, vim.ui.input = run, input
	end)

	local function answer_version_with(value)
		vim.ui.input = function(_, on_confirm)
			on_confirm(value)
		end
	end

	it("does nothing when the version prompt is cancelled", function()
		answer_version_with(nil) -- <Esc>

		package_.add({ project = "/repo/App.csproj", name = "Dapper" })

		assert.are.same({}, calls)
	end)

	it("installs the latest version on an empty answer", function()
		answer_version_with("")

		package_.add({ project = "/repo/App.csproj", name = "Dapper" })

		assert.are.same({ "add /repo/App.csproj package Dapper" }, calls)
	end)

	it("installs the version given", function()
		answer_version_with("2.1.35")

		package_.add({ project = "/repo/App.csproj", name = "Dapper" })

		assert.are.same({ "add /repo/App.csproj package Dapper --version 2.1.35" }, calls)
	end)
end)
