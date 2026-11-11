local build = require("csnew.build")
local dotnet = require("csnew.dotnet")

describe("build.parse_diagnostics", function()
	it("turns compiler output into quickfix items", function()
		local items = build.parse_diagnostics(table.concat({
			"/repo/src/App/Program.cs(2,24): error CS1002: ; expected [/repo/src/App/App.csproj]",
			"/repo/src/App/Util.cs(10,5): warning CS0168: The variable 'x' is declared but never used [/repo/src/App/App.csproj]",
			"",
			"Build FAILED.",
			"    1 Warning(s)",
			"    1 Error(s)",
		}, "\n"))

		assert.are.same({
			{ filename = "/repo/src/App/Program.cs", lnum = 2, col = 24, type = "E", text = "CS1002: ; expected" },
			{
				filename = "/repo/src/App/Util.cs",
				lnum = 10,
				col = 5,
				type = "W",
				text = "CS0168: The variable 'x' is declared but never used",
			},
		}, items)
	end)

	it("reports each diagnostic once, although msbuild prints it twice", function()
		local line = "/repo/Program.cs(2,24): error CS1002: ; expected [/repo/App.csproj]"

		assert.are.same(1, #build.parse_diagnostics(line .. "\n\nBuild FAILED.\n\n" .. line))
	end)

	it("copes with parentheses in the path and CRLF line endings", function()
		local items = build.parse_diagnostics("/repo (copy)/Program.cs(7,1): error CS0103: nope [/repo (copy)/App.csproj]\r\n")

		assert.are.same("/repo (copy)/Program.cs", items[1].filename)
		assert.are.same(7, items[1].lnum)
	end)

	it("ignores lines that are not diagnostics", function()
		assert.are.same({}, build.parse_diagnostics("Determining projects to restore...\nTime Elapsed 00:00:01.20"))
		assert.are.same({}, build.parse_diagnostics(nil))
	end)
end)

describe("build.run", function()
	local original_run, original_notify

	before_each(function()
		original_run, original_notify = dotnet.run, vim.notify
		vim.notify = function() end
	end)

	after_each(function()
		dotnet.run, vim.notify = original_run, original_notify
	end)

	it("passes the configuration on, so the output lands where the debugger looks", function()
		local seen
		dotnet.run = function(args)
			seen = args
			return true
		end

		build.run({ target = "/repo/App.csproj", configuration = "Release" })
		assert.are.same({ "build", "/repo/App.csproj", "--nologo", "-v", "q", "-c", "Release" }, seen)

		build.run({ target = "/repo/App.csproj" })
		assert.are.same({ "build", "/repo/App.csproj", "--nologo", "-v", "q" }, seen)
	end)

	it("still completes when dotnet could not be started", function()
		dotnet.run = function()
			return false
		end
		local result

		build.run({
			target = "/repo/App.csproj",
			on_done = function(ok)
				result = ok
			end,
		})

		assert.is_false(result)
	end)
end)
