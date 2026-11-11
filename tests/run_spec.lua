local h = require("tests.helpers")
local run = require("csnew.run")

describe("run.strip_jsonc", function()
	it("removes comments and trailing commas", function()
		local text = table.concat({
			"{",
			"  // line comment",
			'  "a": 1, /* block',
			"  comment */",
			'  "b": [1, 2, ],',
			"}",
		}, "\n")

		assert.are.same({ a = 1, b = { 1, 2 } }, vim.json.decode(run.strip_jsonc(text)))
	end)

	it("leaves strings alone", function()
		local text = [[{ "url": "http://localhost:5000", "note": "a /* b */ c, }", "q": "say \"hi\" // ok" }]]

		assert.are.same(vim.json.decode(text), vim.json.decode(run.strip_jsonc(text)))
	end)
end)

describe("run.launch_profiles", function()
	local function profiles(lines)
		return run.launch_profiles(h.write(h.tmpdir() .. "/Properties/launchSettings.json", lines))
	end

	it("reads project profiles, sorted, with applicationUrl as ASPNETCORE_URLS", function()
		local result = profiles({
			"{",
			'  "profiles": {',
			'    "https": {',
			'      "commandName": "Project",',
			'      "applicationUrl": "https://localhost:7260;http://localhost:5252",',
			'      "commandLineArgs": "--seed  --verbose",',
			'      "environmentVariables": { "ASPNETCORE_ENVIRONMENT": "Development", "RETRIES": 3 }',
			"    },",
			'    "IIS Express": { "commandName": "IISExpress" },',
			'    "http": { "commandName": "Project", "applicationUrl": "http://localhost:5252" }',
			"  }",
			"}",
		})

		assert.are.same({
			{ name = "http", env = { ASPNETCORE_URLS = "http://localhost:5252" } },
			{
				name = "https",
				env = {
					ASPNETCORE_ENVIRONMENT = "Development",
					ASPNETCORE_URLS = "https://localhost:7260;http://localhost:5252",
					RETRIES = "3",
				},
				args = { "--seed", "--verbose" },
			},
		}, result)
	end)

	it("does not override an explicit ASPNETCORE_URLS", function()
		local result = profiles({
			'{ "profiles": { "p": { "commandName": "Project", "applicationUrl": "http://localhost:1",',
			'  "environmentVariables": { "ASPNETCORE_URLS": "http://localhost:2" } } } }',
		})

		assert.are.same("http://localhost:2", result[1].env.ASPNETCORE_URLS)
	end)

	it("accepts the byte order mark the dotnet templates write", function()
		local result = profiles({ '\239\187\191{ "profiles": { "http": { "commandName": "Project" } } }' })

		assert.are.same("http", result[1].name)
	end)

	it("accepts comments and trailing commas, like the dotnet CLI does", function()
		local result = profiles({
			"{",
			"  // which profile `dotnet run` uses",
			'  "profiles": {',
			'    "http": { "commandName": "Project", }, /* default */',
			"  },",
			"}",
		})

		assert.are.same("http", result[1].name)
	end)

	it("returns nothing for a missing or broken file", function()
		assert.are.same({}, run.launch_profiles(h.tmpdir() .. "/nope.json"))
		assert.are.same({}, profiles({ "{ not json" }))
		assert.are.same({}, profiles({ "[]" }))
	end)
end)

describe("run.compose_args", function()
	it("builds the dotnet run / watch command lines", function()
		assert.are.same({ "run", "--project", "/p/App.csproj" }, run.compose_args("run", "/p/App.csproj"))
		assert.are.same(
			{ "run", "--project", "/p/App.csproj", "--launch-profile", "https" },
			run.compose_args("run", "/p/App.csproj", "https")
		)
		assert.are.same(
			{ "watch", "--project", "/p/App.csproj", "run", "--launch-profile", "https" },
			run.compose_args("watch", "/p/App.csproj", "https")
		)
	end)
end)

describe("the run terminal", function()
	it("does not pile up buffers when its window is closed between runs", function()
		local function terminals()
			return #vim.tbl_filter(function(buf)
				return vim.bo[buf].buftype == "terminal"
			end, vim.api.nvim_list_bufs())
		end
		local project = h.csproj(h.tmpdir() .. "/App.csproj", { "<OutputType>Exe</OutputType>" })
		-- `dotnet` is replaced by a command that exits at once: only the
		-- buffer bookkeeping is under test
		local jobstart, termopen = vim.fn.jobstart, vim.fn.termopen
		vim.fn.jobstart = function(_, opts)
			return jobstart({ "true" }, opts)
		end
		vim.fn.termopen = function(_, opts)
			return termopen({ "true" }, opts)
		end

		for _ = 1, 3 do
			run.run({ project = project })
			vim.cmd("close")
		end
		local open = terminals()
		local notify = vim.notify
		vim.notify = function() end
		run.stop()

		vim.notify = notify
		vim.fn.jobstart, vim.fn.termopen = jobstart, termopen
		assert.are.same(1, open)
		assert.are.same(0, terminals())
	end)
end)
