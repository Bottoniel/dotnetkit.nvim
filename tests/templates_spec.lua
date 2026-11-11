local create = require("csnew.create")
local templates = require("csnew.templates")

describe("templates.render", function()
	it("uses a file-scoped namespace by default", function()
		local lines, cursor = templates.render("class", "Order", "Shop.Models")

		assert.are.same({
			"namespace Shop.Models;",
			"",
			"public class Order",
			"{",
			"    ",
			"}",
		}, lines)
		assert.are.same({ 5, 4 }, cursor)
	end)

	it("puts the cursor inside the record's parameter list", function()
		local lines, cursor = templates.render("record", "Money", "Shop")

		assert.are.same("public record Money();", lines[3])
		assert.are.same({ 3, #"public record Money(" }, cursor)
	end)

	it("adds the MVC using to controllers", function()
		local lines = templates.render("controller", "OrdersController", "Shop.Api")

		assert.are.same({
			"using Microsoft.AspNetCore.Mvc;",
			"",
			"namespace Shop.Api;",
			"",
			"[ApiController]",
			'[Route("api/[controller]")]',
			"public class OrdersController : ControllerBase",
			"{",
			"    ",
			"}",
		}, lines)
	end)

	it("uses a primary constructor for exceptions on C# 12+", function()
		local lines, cursor = templates.render("exception", "NotFoundException", "Shop", { lang = 12 })

		assert.are.same({
			"namespace Shop;",
			"",
			"public sealed class NotFoundException(string message) : Exception(message);",
		}, lines)
		assert.are.same({ 3, #lines[3] }, cursor)
	end)

	it("writes a classic constructor before C# 12", function()
		local lines, cursor = templates.render("exception", "NotFoundException", "Shop", { lang = 10 })

		assert.are.same({
			"namespace Shop;",
			"",
			"public sealed class NotFoundException : Exception",
			"{",
			"    public NotFoundException(string message) : base(message)",
			"    {",
			"    }",
			"}",
		}, lines)
		assert.are.same({ 8, 1 }, cursor)
	end)

	it("uses a block namespace before C# 10", function()
		local lines, cursor = templates.render("class", "Order", "Shop.Models", { lang = 7.3 })

		assert.are.same({
			"namespace Shop.Models",
			"{",
			"    public class Order",
			"    {",
			"        ",
			"    }",
			"}",
		}, lines)
		assert.are.same({ 5, 8 }, cursor)
	end)

	it("adds using System when the project has no implicit usings", function()
		local lines = templates.render("exception", "OopsException", "Shop", { lang = 7.3, implicit_usings = false })

		assert.are.same({ "using System;", "", "namespace Shop", "{" }, vim.list_slice(lines, 1, 4))
		assert.are.same("namespace Shop;", templates.render("exception", "OopsException", "Shop", { implicit_usings = true })[1])
	end)

	it("returns nothing for an unknown kind", function()
		assert.is_nil(templates.render("struct", "X", "Y"))
	end)

	it("splits at the cursor without losing text", function()
		for _, kind in ipairs(templates.kinds) do
			for _, lang in ipairs({ 7.3, 10, 12 }) do
				local lines = templates.render(kind, "Sample", "App", { lang = lang })
				local before, after = templates.split_at_cursor(kind, "Sample", "App", { lang = lang })
				local joined = table.concat(before, "\n") .. table.concat(after, "\n")
				assert.are.same(table.concat(lines, "\n"), joined, kind .. " " .. lang)
			end
		end
	end)
end)

describe("type names", function()
	it("applies the naming conventions of each kind", function()
		assert.are.same("IOrderService", create.type_name("interface", "OrderService"))
		assert.are.same("IOrderService", create.type_name("interface", "IOrderService"))
		assert.are.same("IItem", create.type_name("interface", "Item"))
		assert.are.same("NotFoundException", create.type_name("exception", "NotFound"))
		assert.are.same("OrdersController", create.type_name("controller", "Orders"))
		assert.are.same("Order", create.type_name("class", "  Order.cs "))
	end)

	it("accepts C# identifiers, including non-ASCII letters", function()
		assert.is_true(create.valid_identifier("Order"))
		assert.is_true(create.valid_identifier("_order2"))
		assert.is_true(create.valid_identifier("Año"))
		assert.is_false(create.valid_identifier(""))
		assert.is_false(create.valid_identifier("2Fast"))
		assert.is_false(create.valid_identifier("Order Item"))
		assert.is_false(create.valid_identifier("Order.Item"))
	end)
end)
