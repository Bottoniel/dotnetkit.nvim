local M = {}

M.kinds = { "class", "interface", "record", "enum", "controller", "exception" }

local bodies = {
	class = [[
namespace {{namespace}};

public class {{name}}
{
    {{cursor}}
}
]],
	interface = [[
namespace {{namespace}};

public interface {{name}}
{
    {{cursor}}
}
]],
	record = [[
namespace {{namespace}};

public record {{name}}({{cursor}});
]],
	enum = [[
namespace {{namespace}};

public enum {{name}}
{
    {{cursor}}
}
]],
	controller = [[
using Microsoft.AspNetCore.Mvc;

namespace {{namespace}};

[ApiController]
[Route("api/[controller]")]
public class {{name}} : ControllerBase
{
    {{cursor}}
}
]],
	exception = [[
namespace {{namespace}};

public sealed class {{name}}(string message) : Exception(message);
]],
}

function M.render(kind, name, namespace)
	local body = bodies[kind]
	if not body then
		return nil, nil
	end
	body = body:gsub("{{namespace}}", namespace):gsub("{{name}}", name)
	body = body:gsub("\n$", "")

	local lines = {}
	local cursor = { 1, 0 }
	for i, line in ipairs(vim.split(body, "\n", { plain = true })) do
		local col = line:find("{{cursor}}", 1, true)
		if col then
			cursor = { i, col - 1 }
			line = line:gsub("{{cursor}}", "")
		end
		table.insert(lines, line)
	end
	if kind == "exception" then
		cursor = { #lines, #lines[#lines] }
	end
	return lines, cursor
end

function M.split_at_cursor(kind, name, namespace)
	local lines, cursor = M.render(kind, name, namespace)
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
