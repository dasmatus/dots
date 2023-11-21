local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
	vim.fn.system({
		"git",
		"clone",
		"--filter=blob:none",
		"https://github.com/folke/lazy.nvim.git",
		"--branch=stable", -- latest stable release
		lazypath,
	})
end
vim.opt.rtp:prepend(lazypath)
vim.g.mapleader = "\\"
require("lazy").setup({
	"folke/which-key.nvim",
	"echasnovski/mini.nvim",
	"folke/tokyonight.nvim",
	"folke/trouble.nvim",
	{'williamboman/mason.nvim', dependencies = 'williamboman/mason-lspconfig.nvim'},
	'neovim/nvim-lspconfig',
	{'mfussenegger/nvim-dap', dependencies = 'rcarriga/nvim-dap-ui'},
	'mfussenegger/nvim-lint',
	'mhartington/formatter.nvim',
	'folke/todo-comments.nvim',
	{ "folke/todo-comments.nvim", dependencies = { "nvim-lua/plenary.nvim" }, },
	'simrat39/rust-tools.nvim',
	'nvim-treesitter/nvim-treesitter',
	'Pocco81/auto-save.nvim',
	{'SirVer/UltiSnips', dependencies = 'honza/vim-snippets' },
	{'hrsh7th/nvim-cmp', dependencies = {'hrsh7th/cmp-buffer', 'hrsh7th/cmp-path', 'hrsh7th/cmp-nvim-lsp', 'quangnguyen30192/cmp-nvim-ultisnips', 'onsails/lspkind.nvim', 'hrsh7th/cmp-nvim-lua', 'hrsh7th/cmp-nvim-lua'}, },
	{ "utilyre/barbecue.nvim", name = "barbecue", version = "*", dependencies = { "SmiteshP/nvim-navic", "nvim-tree/nvim-web-devicons", },},
	{'gelguy/wilder.nvim', build = ":UpdateRemotePlugins", dependencies = "romgrk/fzy-lua-native"},
	{'folke/todo-comments.nvim', dependencies = "nvim-lua/plenary.nvim"},
	{'seblj/nvim-tabline', dependencies = { 'nvim-tree/nvim-web-devicons' }, },
	'vim-autoformat/vim-autoformat',
	{'nvim-lualine/lualine.nvim', dependencies = 'nvim-tree/nvim-web-devicons'},
	{'nvim-tree/nvim-tree.lua', dependencies = 'nvim-tree/nvim-web-devicons'},
	'andweeb/presence.nvim',
	'tpope/vim-fugitive',
	{
		'saecki/crates.nvim',
		tag = 'v0.4.0',
		dependencies = { 'nvim-lua/plenary.nvim' },
		event = { "BufRead Cargo.toml" },
		config = function()
			require('crates').setup() {
				src = {
					cmp = {
						enabled = true,
					},
				},

			}
		end,
	},
	{
		'glepnir/dashboard-nvim',
		config = function()
			require('dashboard').setup {
				theme = 'hyper',
				config = {
					week_header = {
						enable = true,
					},
					shortcut = {
						{ desc = '󰊳 Update', group = '@property', action = 'Lazy update', key = 'u' },
						{
							icon = ' ',
							icon_hl = '@variable',
							desc = 'Files',
							group = 'Label',
							action = 'NvimTreeOpen .',
							key = 'f',
						},
						{
							desc = 'Projects',
							group = 'DiagnosticHint',
							action = 'NvimTreeOpen ~/proj',
							key = 'p',
						},
						{
							desc = 'Neovim configuration',
							group = 'Number',
							action = 'NvimTreeOpen ~/.config/nvim/',
							key = 'n',
						},
					},
				},
			}
		end,
		dependencies = { {'nvim-tree/nvim-web-devicons'}}
	},
	'ollykel/v-vim',
	{'pearofducks/ansible-vim', build = "./UltiSnips/generate.sh"},
	{'akinsho/toggleterm.nvim', version = "*", config = true},
})
