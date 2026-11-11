local dotnet = require("csnew.dotnet")
local reference = require("csnew.reference")

local M = {}

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function first_nonempty(text)
	local lines = {}
	for line in (text or ""):gmatch("[^\r\n]+") do
		if line:match("%S") then
			table.insert(lines, line)
			if #lines >= 8 then
				break
			end
		end
	end
	return table.concat(lines, "\n")
end

function M.parse_diagnostics(text)
	local items = {}
	local seen = {}
	for line in (text or ""):gmatch("[^\r\n]+") do
		local file, lnum, col, kind, code, msg =
			line:match("^(.-)%((%d+),(%d+)%)%s*:%s*(%a+)%s+(%S+):%s+(.*)$")
		if file and (kind == "error" or kind == "warning") then
			msg = msg:gsub("%s*%[.-%]%s*$", "")
			local item_text = code .. ": " .. msg
			local key = file .. ":" .. lnum .. ":" .. col .. ":" .. item_text
			if not seen[key] then
				seen[key] = true
				table.insert(items, {
					filename = file,
					lnum = tonumber(lnum),
					col = tonumber(col),
					type = kind == "error" and "E" or "W",
					text = item_text,
				})
			end
		end
	end
	return items
end

local function resolve_target(preset, cb)
	if preset and preset ~= "" then
		cb(dotnet.normalize(preset))
		return
	end
	local solutions = dotnet.find_solutions(dotnet.workspace_root())
	if #solutions == 1 then
		cb(solutions[1])
		return
	end
	if #solutions > 1 then
		dotnet.pick_solution(cb)
		return
	end
	local current = reference.current_project()
	if current then
		cb(current)
		return
	end
	vim.notify("dotnetkit: no .sln or .csproj to build", vim.log.levels.ERROR)
end

-- opts.target        .sln / .csproj; resolved from the workspace when missing
-- opts.configuration passed as -c, so the output matches what the caller
--                    will look for under bin/<configuration>
-- opts.on_done(ok, items)
function M.run(opts)
	opts = opts or {}
	resolve_target(opts.target, function(target)
		local args = { "build", target, "--nologo", "-v", "q" }
		if opts.configuration and opts.configuration ~= "" then
			vim.list_extend(args, { "-c", opts.configuration })
		end
		local started = dotnet.run(args, function(ok, stdout, stderr)
			local items = M.parse_diagnostics((stdout or "") .. "\n" .. (stderr or ""))
			vim.fn.setqflist({}, "r", { title = "dotnet build " .. vim.fn.fnamemodify(target, ":t"), items = items })
			local errors = 0
			local warnings = 0
			for _, item in ipairs(items) do
				if item.type == "E" then
					errors = errors + 1
				else
					warnings = warnings + 1
				end
			end
			if not ok then
				-- nothing to jump to when the failure has no file location
				-- (e.g. a NuGet error); the notification carries the detail
				if #items > 0 then
					vim.cmd("copen")
				end
				local msg = ("dotnetkit: build failed (%d error(s), %d warning(s))"):format(errors, warnings)
				if #items == 0 then
					local detail = stderr
					if detail == nil or trim(detail) == "" then
						detail = stdout
					end
					local extra = first_nonempty(detail)
					if extra ~= "" then
						msg = "dotnetkit: build failed\n" .. extra
					end
				end
				vim.notify(msg, vim.log.levels.ERROR)
			else
				vim.cmd("cclose")
				vim.notify(("dotnetkit: build succeeded (%d warning(s))"):format(warnings), vim.log.levels.INFO)
			end
			if opts.on_done then
				opts.on_done(ok, items)
			end
		end, {
			progress_msg = "dotnetkit: building " .. vim.fn.fnamemodify(target, ":t"),
			success_msg = false,
			fail_msg = false,
		})
		-- dotnet never ran: still complete, so callers waiting on the build
		-- (the debug launch) are not left hanging
		if not started and opts.on_done then
			opts.on_done(false, {})
		end
	end)
end

return M
