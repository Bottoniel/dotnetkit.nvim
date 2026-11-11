local M = {}

M.kinds = { "class", "interface", "record", "enum", "controller", "exception" }

-- Type declarations without their namespace; {{cursor}} marks where insert
-- mode starts.
local bodies = {
	class = {
		"public class {{name}}",
		"{",
		"    {{cursor}}",
		"}",
	},
	interface = {
		"public interface {{name}}",
		"{",
		"    {{cursor}}",
		"}",
	},
	record = {
		"public record {{name}}({{cursor}});",
	},
	enum = {
		"public enum {{name}}",
		"{",
		"    {{cursor}}",
		"}",
	},
	controller = {
		"[ApiController]",
		'[Route("api/[controller]")]',
		"public class {{name}} : ControllerBase",
		"{",
		"    {{cursor}}",
		"}",
	},
	exception = {
		"public sealed class {{name}}(string message) : Exception(message);{{cursor}}",
	},
}

-- Primary constructors need C# 12.
local exception_before_12 = {
	"public sealed class {{name}} : Exception",
	"{",
	"    public {{name}}(string message) : base(message)",
	"    {",
	"    }",
	"}{{cursor}}",
}

local FILE_SCOPED_NAMESPACE = 10
local PRIMARY_CONSTRUCTORS = 12

-- opts (both optional, see namespace.project_info):
--   lang            C# version of the project; nil means a modern one
--   implicit_usings false adds the usings a template relies on
function M.render(kind, name, namespace, opts)
	local body = bodies[kind]
	if not body then
		return nil, nil
	end
	opts = opts or {}
	local lang = opts.lang or math.huge
	if kind == "exception" and lang < PRIMARY_CONSTRUCTORS then
		body = exception_before_12
	end

	local lines = {}
	if kind == "controller" then
		vim.list_extend(lines, { "using Microsoft.AspNetCore.Mvc;", "" })
	elseif kind == "exception" and opts.implicit_usings == false then
		vim.list_extend(lines, { "using System;", "" })
	end

	if lang >= FILE_SCOPED_NAMESPACE then
		vim.list_extend(lines, { "namespace " .. namespace .. ";", "" })
		vim.list_extend(lines, body)
	else
		vim.list_extend(lines, { "namespace " .. namespace, "{" })
		for _, line in ipairs(body) do
			table.insert(lines, line == "" and "" or ("    " .. line))
		end
		table.insert(lines, "}")
	end

	local cursor = { 1, 0 }
	for i, line in ipairs(lines) do
		line = line:gsub("{{name}}", function()
			return name
		end)
		local col = line:find("{{cursor}}", 1, true)
		if col then
			cursor = { i, col - 1 }
			line = line:gsub("{{cursor}}", "")
		end
		lines[i] = line
	end
	return lines, cursor
end

function M.split_at_cursor(kind, name, namespace, opts)
	local lines, cursor = M.render(kind, name, namespace, opts)
	if not lines then
		return nil
	end
	local row, col = cursor[1], cursor[2]
	local before = {}
	for i = 1, row - 1 do
		before[#before + 1] = lines[i]
	end
	local line = lines[row] or ""
	before[#before + 1] = line:sub(1, col)
	local after = { line:sub(col + 1) }
	for i = row + 1, #lines do
		after[#after + 1] = lines[i]
	end
	return before, after
end

return M
