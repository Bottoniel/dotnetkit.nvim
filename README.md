# dotnetkit.nvim

Neovim plugin for day-to-day .NET work: create C# types, manage solutions and project references, NuGet, Entity Framework, build/run/watch, and debug.

Requires **Neovim 0.10+**.

## Features

- Create C# types (class, interface, record, enum, controller, exception) with file-scoped namespace inferred from the `.csproj`
- LuaSnip snippets (`cls`, `iface`, `rec`, `enm`, `ctrl`, `exc`)
- Add/remove project references and solution entries (`.sln` and `.slnx`)
- NuGet: add, list (with outdated), remove, update
- Entity Framework: migrate, update, remove, list, SQL script
- Build into the quickfix list; run / watch / stop
- Debug launch via nvim-dap + netcoredbg
- Per-repo config (`.csnew.lua`) so layered apps do not need a global setup

## Requirements

| Tool | Required for |
|---|---|
| Neovim ≥ 0.10 | everything (`vim.system`) |
| .NET SDK (`dotnet` on `PATH`) | everything except `:CsNew` / snippets |
| [`dotnet-ef`](https://learn.microsoft.com/ef/core/cli/dotnet) (`dotnet tool install --global dotnet-ef`) | `:EfMigrate`, `:EfUpdate`, … |
| `Microsoft.EntityFrameworkCore.Design` on the **startup** project | EF design-time (`DbContext` creation) |
| [LuaSnip](https://github.com/L3MON4D3/LuaSnip) | snippets (`cls`, `iface`, …) |
| [nvim-dap](https://github.com/mfussenegger/nvim-dap) + [netcoredbg](https://github.com/Samsung/netcoredbg) | `:CsDebugRun` |
| [dressing.nvim](https://github.com/stevearc/dressing.nvim) or [telescope-ui-select](https://github.com/nvim-telescope/telescope-ui-select.nvim) | nicer pickers (`vim.ui.select`) |
| [nvim-tree.lua](https://github.com/nvim-tree/nvim-tree.lua) | optional: create a type on the node under the cursor |
| roslyn / OmniSharp LSP | post-change `:LspRestart` actually reloads C# |

## Install (lazy.nvim)

Lua API stays `require("csnew")` (setup, create, dap). The GitHub repo is `dotnetkit.nvim`.

### Minimal

Core commands only. No snippets, no debug.

```lua
{
	"Bottoniel/dotnetkit.nvim",
	ft = "cs",
	cmd = {
		"CsNew",
		"CsBuild",
		"CsRun",
		"CsWatch",
		"CsStop",
		"CsAddRef",
		"CsRemoveRef",
		"CsSlnAdd",
		"CsSlnRemove",
		"CsAddPkg",
		"CsListPkg",
		"CsRemovePkg",
		"CsUpdatePkg",
		"CsNewProject",
		"EfMigrate",
		"EfUpdate",
		"EfRemove",
		"EfList",
		"EfScript",
	},
	opts = {},
}
```

`opts = {}` calls `require("csnew").setup({})`. Without `setup()`, snippets are not registered.

### Recommended

Snippets + a keymap. Debug is a separate spec (see below).

```lua
{
	"Bottoniel/dotnetkit.nvim",
	ft = "cs",
	dependencies = { "L3MON4D3/LuaSnip" },
	cmd = {
		"CsNew",
		"CsBuild",
		"CsRun",
		"CsWatch",
		"CsStop",
		"CsAddRef",
		"CsRemoveRef",
		"CsSlnAdd",
		"CsSlnRemove",
		"CsAddPkg",
		"CsListPkg",
		"CsRemovePkg",
		"CsUpdatePkg",
		"CsNewProject",
		"CsDebugRun",
		"EfMigrate",
		"EfUpdate",
		"EfRemove",
		"EfList",
		"EfScript",
	},
	keys = {
		{
			"<leader>cn",
			function()
				require("csnew").create()
			end,
			desc = "New C# type",
		},
	},
	opts = {},
}
```

### Full workspace (debug + pickers)

csnew does **not** install nvim-dap for you. Add a companion spec and install `netcoredbg` (Mason: `:MasonInstall netcoredbg`).

```lua
{
	"mfussenegger/nvim-dap",
	dependencies = {
		"rcarriga/nvim-dap-ui",
		"nvim-neotest/nvim-nio",
	},
	keys = {
		{ "<leader>db", function() require("dap").toggle_breakpoint() end, desc = "Debug: toggle breakpoint" },
		{ "<leader>dB", function() require("dap").set_breakpoint(vim.fn.input("Breakpoint condition: ")) end, desc = "Debug: conditional breakpoint" },
		{ "<leader>dd", function() require("dap").clear_breakpoints() end, desc = "Debug: clear all breakpoints" },
		{ "<leader>dl", function() require("dap").list_breakpoints() vim.cmd("copen") end, desc = "Debug: list breakpoints" },
		{ "<leader>dc", function() require("dap").continue() end, desc = "Debug: continue" },
		{ "<leader>do", function() require("dap").step_over() end, desc = "Debug: step over" },
		{ "<leader>di", function() require("dap").step_into() end, desc = "Debug: step into" },
		{ "<leader>dO", function() require("dap").step_out() end, desc = "Debug: step out" },
		{ "<leader>dt", function() require("dap").terminate() end, desc = "Debug: terminate" },
		{ "<leader>du", function() require("dapui").toggle() end, desc = "Debug: toggle UI" },
		{ "<leader>dr", function() require("csnew.dap").debug_run() end, desc = "Debug: run current project" },
	},
	config = function()
		local dap, dapui = require("dap"), require("dapui")
		dapui.setup()
		dap.listeners.after.event_initialized["dapui_config"] = function()
			dapui.open()
		end
		dap.listeners.before.event_terminated["dapui_config"] = function()
			dapui.close()
		end
		dap.listeners.before.event_exited["dapui_config"] = function()
			dapui.close()
		end
		require("csnew.dap").setup()
	end,
}
```

For Telescope pickers instead of the default `vim.ui.select`, add `nvim-telescope/telescope-ui-select.nvim` and `telescope.load_extension("ui-select")`.

## Commands

| Command | CLI / action |
|---|---|
| `:CsNew [kind] [name]` | Create a C# type in the current directory |
| `:CsNewProject [template] [name] [outdir]` | `dotnet new` (console, classlib, webapi, web, xunit, nunit, mstest); offers sln add |
| `:CsAddRef [target] [ref]` | `dotnet add reference` |
| `:CsRemoveRef [target] [ref]` | `dotnet remove reference` |
| `:CsSlnAdd [project]` | `dotnet sln add` |
| `:CsSlnRemove [project]` | `dotnet sln remove` |
| `:CsAddPkg [name] [version]` | `dotnet add package` |
| `:CsListPkg [project]` | `dotnet list package --outdated` (scratch buffer) |
| `:CsRemovePkg [name]` | `dotnet remove package` |
| `:CsUpdatePkg [name] [version]` | update one outdated package (or named) |
| `:CsBuild [target]` | `dotnet build` → quickfix (`:cnext`) |
| `:CsRun [project]` | `dotnet run` + `launchSettings.json` profile picker |
| `:CsWatch [project]` | `dotnet watch run` |
| `:CsStop` | stop the Run/Watch job |
| `:CsDebugRun [project]` | launch `bin/Debug/*/<project>.dll` with nvim-dap |
| `:EfMigrate [name]` | `dotnet ef migrations add` |
| `:EfUpdate [target]` | `dotnet ef database update` (empty = latest, `0` = revert all) |
| `:EfRemove` | `dotnet ef migrations remove` |
| `:EfList` | `dotnet ef migrations list` (scratch buffer) |
| `:EfScript` | `dotnet ef migrations script --idempotent` → `Migrations.sql` |

Arguments are optional. Missing pieces are asked with `vim.ui.select` / `vim.ui.input`.

After sln / reference / package changes the plugin runs `dotnet clean` + `dotnet restore` on the solution and `:LspRestart` (configurable).

## Snippets

Requires **LuaSnip** and `setup()` (`opts = {}` is enough).

In a `.cs` buffer, type the trigger and expand with your LuaSnip / nvim-cmp mapping:

| Trigger | Type | Naming |
|---|---|---|
| `cls` | class | as typed |
| `iface` | interface | `I` prefix if missing |
| `rec` | record | as typed |
| `enm` | enum | as typed |
| `ctrl` | controller | `Controller` suffix if missing |
| `exc` | exception | `Exception` suffix if missing |

Namespace is `RootNamespace` (or the `.csproj` name) plus folders relative to the project.

## Optional: nvim-tree

The plugin works **without** nvim-tree. `:CsNew` and `<leader>cn` use the current buffer directory (or `cwd` if there is no file).

To create the type **on the tree node under the cursor**, add this to nvim-tree `on_attach`:

```lua
local function on_attach(bufnr)
	local api = require("nvim-tree.api")
	api.config.mappings.default_on_attach(bufnr)

	vim.keymap.set("n", "<leader>cn", function()
		local node = api.tree.get_node_under_cursor()
		if not node then
			return
		end
		local dir = node.absolute_path
		if node.type ~= "directory" then
			dir = vim.fn.fnamemodify(dir, ":h")
		end
		require("csnew").create({ dir = dir })
	end, { buffer = bufnr, noremap = true, silent = true, desc = "New C# type" })
end
```

Mark `dotnetkit.nvim` as a dependency of nvim-tree so the module is available when the tree loads.

## Configuration

```lua
require("csnew").setup({
	dotnet = {
		-- run after sln / reference / package changes (on the .sln)
		after_change = { "clean", "restore", "lsp_restart" },
	},
	ef = {
		project = "src/MyApp.Data",          -- --project (relative to git root or absolute)
		startup_project = "src/MyApp.Api",   -- --startup-project
		context = "AppDbContext",            -- --context when several DbContexts exist
		output_dir = "Migrations",           -- -o for migrations add
		script_output = "Migrations.sql",    -- :EfScript output
		script_idempotent = true,            -- false for SQLite (no idempotent scripts)
	},
})
```

All `ef.*` keys are optional. With nothing set:

- one `.csproj` in the repo → used as both `--project` and `--startup-project`
- several → two pickers (migrations project, then startup). The choice is remembered for the session (`Use last: X -> Y`)

### Per-repo: `.csnew.lua`

Put this file at the **git root** (same folder as `.git` / the `.sln`). Same schema as `setup()`. It **overrides** the global setup (deep merge: defaults < `setup()` < `.csnew.lua`).

```lua
-- .csnew.lua
return {
	ef = {
		project = "src/Control.Infrastructure",
		startup_project = "src/Control.Web",
	},
}
```

If the file is missing, pickers still work. If it is broken, the plugin notifies and falls back to pickers.

## Workflows

**New type** — open a `.cs` (or a folder in nvim-tree) → `:CsNew` or `<leader>cn` → pick kind + name.

**New project** — `:CsNewProject webapi MyApi` → confirm sln add.

**Build** — `:CsBuild` (solution if unique, else picker) → errors in quickfix → `:cnext`.

**Run an API** — `:CsRun` → pick project / launch profile → split terminal. `:CsStop` to kill it. `:CsWatch` for `dotnet watch`.

**EF** — `:EfMigrate AddUsers` → `:EfUpdate`. Target empty = latest, `0` = revert all, or a migration name from `:EfList`.

**Debug**

1. `:CsBuild` (needs `bin/Debug/<tfm>/<Project>.dll`)
2. `<leader>db` on a line
3. `<leader>dr` or `:CsDebugRun`
4. dap-ui opens; step with `<leader>do` / `<leader>di`
5. `<leader>dt` to stop; `<leader>dd` clears all breakpoints; `<leader>dl` lists them in the quickfix

**NuGet** — `:CsAddPkg Newtonsoft.Json`, `:CsListPkg`, `:CsUpdatePkg`, `:CsRemovePkg`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Unable to create a 'DbContext'… DbContextOptions` | Layered app: set `ef.startup_project` (or `.csnew.lua`) to the project that has `Program.cs` + `AddDbContext`. The Infrastructure project is not a host. |
| `Generating idempotent scripts… not supported for SQLite` | `ef.script_idempotent = false` |
| `dotnet-ef not available` | `dotnet tool install --global dotnet-ef` |
| `netcoredbg not found` | `:MasonInstall netcoredbg` (or put `netcoredbg` on `PATH`) |
| `no Debug dll found` | `:CsBuild` first |
| Connection error to `localhost:5432` / SQL Server | Not the plugin — Postgres/SQL is down or the connection string is wrong |
| Snippets do nothing | LuaSnip in `dependencies`, and `opts = {}` so `setup()` runs |
| Pickers look ugly | dressing.nvim or telescope-ui-select |

## License

MIT
