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

	-- Editor primitives (deferred — VeryLazy fires before any input is possible)
	{
		"echasnovski/mini.nvim",
		event = "VeryLazy",
		config = function()
			require('nvimcfg.language.autopairs')
			require('nvimcfg.editor.persistence')
		end,
	},
	{ "folke/which-key.nvim", event = "VeryLazy" },

	-- LSP stack: mason + lspconfig + language tooling
	{
		'williamboman/mason.nvim',
		event = { "BufReadPost", "BufNewFile" },
		dependencies = {
			'williamboman/mason-lspconfig.nvim',
			'neovim/nvim-lspconfig',
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
	{ 'tpope/vim-fugitive', cmd = { "Git", "Gvdiffsplit", "Gread", "Gwrite" } },

	-- Rust
	{
		'mrcjkb/rustaceanvim',
		version = '^5',
		ft = "rust",
	},

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
		event = "VeryLazy",
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
	{
		'akinsho/toggleterm.nvim',
		version = "*",
		cmd = "ToggleTerm",
		config = function()
			require('nvimcfg.editor.term')
		end,
	},

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
}, {
	performance = {
		rtp = {
			disabled_plugins = {
				"gzip", "matchit", "matchparen", "netrwPlugin", "tarPlugin",
				"tohtml", "tutor", "zipPlugin", "man", "osc52", "shada",
				"spellfile", "editorconfig",
			},
		},
	},
})
