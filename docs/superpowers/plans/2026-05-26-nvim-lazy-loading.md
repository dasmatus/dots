# Neovim Plugin Lazy Loading Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lazy load heavy Neovim plugins so they only initialize when needed, cutting startup time.

**Architecture:** Use lazy.nvim's `event`, `cmd`, and `ft` triggers on each heavy plugin spec with `config` callbacks that `require()` the existing setup modules. Remove the corresponding `require()` calls from `init.lua` — setup now runs only when the plugin actually loads. Treesitter config is extracted from `lsp.lua` into its own module so it can be lazy-loaded independently.

**Tech Stack:** Neovim, lazy.nvim, Lua

---

## Files

| File | Change |
|---|---|
| `Configuration files/nvim/init.lua` | Remove 8 `require()` calls that move into plugin `config` callbacks |
| `Configuration files/nvim/lua/nvimcfg/plugins.lua` | Full rewrite: add `event`/`cmd`/`ft`/`config` to every plugin spec |
| `Configuration files/nvim/lua/nvimcfg/language/lsp.lua` | Remove `nvim-treesitter.configs` block (extracted below) |
| `Configuration files/nvim/lua/nvimcfg/language/treesitter.lua` | **New** — extracted treesitter setup |

---

### Task 1: Extract treesitter config into its own module

`lsp.lua` currently contains setup for four unrelated plugins: trouble, todo-comments, barbecue, and treesitter. Treesitter loads on a different lazy trigger than the others, so pull it out into its own file.

**Files:**
- Create: `Configuration files/nvim/lua/nvimcfg/language/treesitter.lua`
- Modify: `Configuration files/nvim/lua/nvimcfg/language/lsp.lua`

- [ ] **Step 1: Create `treesitter.lua`**

```lua
require('nvim-treesitter.configs').setup {
	auto_install = true,
	highlight = {
		enable = true,
		additional_vim_regex_highlighting = false,
	},
	ident = { enable = true },
	rainbow = {
		enable = true,
		extended_mode = true,
		max_file_lines = nil,
	}
}
```

- [ ] **Step 2: Remove the treesitter block from `lsp.lua`**

The full content of `lsp.lua` after the edit:

```lua
require("trouble").setup()
require("todo-comments").setup()
require("barbecue.ui").toggle(true)
```

- [ ] **Step 3: Commit**

```bash
git add "Configuration files/nvim/lua/nvimcfg/language/treesitter.lua" \
        "Configuration files/nvim/lua/nvimcfg/language/lsp.lua"
git commit -m "refactor: extract treesitter config into dedicated module"
```

---

### Task 2: Rewrite `plugins.lua` with lazy loading

Replace the current flat plugin list with specs that carry `event`, `cmd`, `ft`, and `config` fields. The grouping logic:

- **mason + lspconfig + rust-tools + trouble + todo-comments + barbecue** all belong to the LSP stack and load on `BufReadPost`/`BufNewFile`.
- **nvim-treesitter** loads on `BufReadPost`/`BufNewFile` independently.
- **nvim-cmp + all completion sources + UltiSnips** load on `InsertEnter`.
- **nvim-dap** loads on DAP commands only.
- **wilder** loads on `CmdlineEnter`.
- **nvim-tree**, **vim-fugitive**, **formatter**, **vim-autoformat** load on their commands.
- **lualine**, **tabline**, **presence**, **auto-save** load on `VeryLazy` (fires right after UI draws).
- **dashboard** loads on `VimEnter`.
- **v-vim**, **ansible-vim** load on their filetypes.
- **tokyonight** is `lazy = false, priority = 1000` — colorscheme must apply before everything else.

**Files:**
- Modify: `Configuration files/nvim/lua/nvimcfg/plugins.lua`

- [ ] **Step 1: Replace `plugins.lua` with the following**

```lua
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
	vim.fn.system({
		"git",
		"clone",
		"--filter=blob:none",
		"https://github.com/folke/lazy.nvim.git",
		"--branch=stable",
		lazypath,
	})
end
vim.opt.rtp:prepend(lazypath)
vim.g.mapleader = "\\"
require("lazy").setup({
	-- Colorscheme: must load before everything else
	{ "folke/tokyonight.nvim", lazy = false, priority = 1000 },

	-- Always-on editor primitives
	"echasnovski/mini.nvim",
	"folke/which-key.nvim",

	-- LSP stack: mason + lspconfig + language tooling
	{
		'williamboman/mason.nvim',
		event = { "BufReadPost", "BufNewFile" },
		dependencies = {
			'williamboman/mason-lspconfig.nvim',
			'neovim/nvim-lspconfig',
			'simrat39/rust-tools.nvim',
			'folke/trouble.nvim',
			{ "folke/todo-comments.nvim", dependencies = { "nvim-lua/plenary.nvim" } },
			{
				"utilyre/barbecue.nvim",
				name = "barbecue",
				version = "*",
				dependencies = { "SmiteshP/nvim-navic", "nvim-tree/nvim-web-devicons" },
			},
		},
		config = function()
			require('nvimcfg.language.mason')
			require('nvimcfg.language.lsp')
		end,
	},

	-- Treesitter: syntax highlighting and parsing
	{
		'nvim-treesitter/nvim-treesitter',
		event = { "BufReadPost", "BufNewFile" },
		config = function()
			require('nvimcfg.language.treesitter')
		end,
	},

	-- Completion engine + all sources + snippets
	{
		'hrsh7th/nvim-cmp',
		event = "InsertEnter",
		dependencies = {
			'hrsh7th/cmp-buffer',
			'hrsh7th/cmp-path',
			'hrsh7th/cmp-nvim-lsp',
			'hrsh7th/cmp-nvim-lua',
			'quangnguyen30192/cmp-nvim-ultisnips',
			'onsails/lspkind.nvim',
			{ 'SirVer/UltiSnips', dependencies = 'honza/vim-snippets' },
		},
		config = function()
			require('nvimcfg.language.cmp')
		end,
	},

	-- Debugger: only when a DAP command is invoked
	{
		'mfussenegger/nvim-dap',
		cmd = { "DapToggleBreakpoint", "DapContinue", "DapStepOver", "DapStepInto", "DapStepOut" },
		dependencies = { 'rcarriga/nvim-dap-ui' },
	},

	-- Lint / format
	{ 'mfussenegger/nvim-lint', event = { "BufReadPost", "BufNewFile" } },
	{ 'mhartington/formatter.nvim', cmd = { "Format", "FormatWrite" } },
	{ 'vim-autoformat/vim-autoformat', cmd = "Autoformat" },

	-- Git
	{ 'tpope/vim-fugitive', cmd = { "Git", "GDiff", "GBlame", "GLog" } },

	-- Rust crates (event-scoped to Cargo.toml)
	{
		'saecki/crates.nvim',
		tag = 'v0.4.0',
		dependencies = { 'nvim-lua/plenary.nvim' },
		event = { "BufRead Cargo.toml" },
		config = function()
			require('crates').setup({
				src = { cmp = { enabled = true } },
			})
		end,
	},

	-- Cmdline popup
	{
		'gelguy/wilder.nvim',
		event = "CmdlineEnter",
		build = ":UpdateRemotePlugins",
		dependencies = { "romgrk/fzy-lua-native" },
		config = function()
			require('nvimcfg.appearance.wilder')
		end,
	},

	-- Statusline
	{
		'nvim-lualine/lualine.nvim',
		event = "VeryLazy",
		dependencies = { 'nvim-tree/nvim-web-devicons' },
		config = function()
			require('nvimcfg.appearance.airline')
		end,
	},

	-- Tabline
	{
		'seblj/nvim-tabline',
		event = "VeryLazy",
		dependencies = { 'nvim-tree/nvim-web-devicons' },
		config = function()
			require('nvimcfg.appearance.tabs')
		end,
	},

	-- File explorer
	{
		'nvim-tree/nvim-tree.lua',
		cmd = { "NvimTreeOpen", "NvimTreeToggle", "NvimTreeFocus" },
		dependencies = { 'nvim-tree/nvim-web-devicons' },
		config = function()
			require('nvimcfg.appearance.nvimtree')
		end,
	},

	-- Auto-save
	{ 'Pocco81/auto-save.nvim', event = "VeryLazy" },

	-- Terminal
	{ 'akinsho/toggleterm.nvim', version = "*", cmd = "ToggleTerm", config = true },

	-- Discord presence
	{
		'andweeb/presence.nvim',
		event = "VeryLazy",
		config = function()
			require('nvimcfg.editor.discord')
		end,
	},

	-- Dashboard
	{
		'glepnir/dashboard-nvim',
		event = "VimEnter",
		dependencies = { 'nvim-tree/nvim-web-devicons' },
		config = function()
			require('dashboard').setup {
				theme = 'hyper',
				config = {
					week_header = { enable = true },
					shortcut = {
						{ desc = '󰊳 Update', group = '@property', action = 'Lazy update', key = 'u' },
						{ icon = ' ', icon_hl = '@variable', desc = 'Files', group = 'Label', action = 'NvimTreeOpen .', key = 'f' },
						{ desc = 'Projects', group = 'DiagnosticHint', action = 'NvimTreeOpen ~/proj', key = 'p' },
						{ desc = 'Neovim configuration', group = 'Number', action = 'NvimTreeOpen ~/.config/nvim/', key = 'n' },
					},
				},
			}
		end,
	},

	-- Filetype-specific
	{ 'ollykel/v-vim', ft = "v" },
	{
		'pearofducks/ansible-vim',
		ft = { "yaml", "yaml.ansible" },
		build = "./UltiSnips/generate.sh",
		config = function()
			require('nvimcfg.language.ansible')
		end,
	},

	-- Shared utility (pulled in as dep, never needs direct loading)
	{ 'nvim-lua/plenary.nvim', lazy = true },
})
```

- [ ] **Step 2: Commit**

```bash
git add "Configuration files/nvim/lua/nvimcfg/plugins.lua"
git commit -m "feat: lazy load heavy plugins via event/cmd/ft triggers"
```

---

### Task 3: Remove redundant requires from `init.lua`

Each removed line now runs inside a plugin `config` callback. Leaving them in `init.lua` would cause a double-setup at best, and a "module not found" crash at worst (if the plugin hasn't loaded yet when init.lua runs).

**Files:**
- Modify: `Configuration files/nvim/init.lua`

- [ ] **Step 1: Replace `init.lua` with the following**

```lua
require("nvimcfg.plugins")            -- Plugin registry + lazy loading
require('nvimcfg.language.autopairs') -- mini.pairs (always-on)
require('nvimcfg.editor.persistence') -- mini.sessions (always-on)
require('nvimcfg.editor.keybinds')    -- Key bindings
require('nvimcfg.editor.opts')        -- Vim options
require('nvimcfg.editor.term')        -- Terminal config
```

- [ ] **Step 2: Commit**

```bash
git add "Configuration files/nvim/init.lua"
git commit -m "chore: remove requires now handled by lazy plugin configs"
```
