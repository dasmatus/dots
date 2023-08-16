-- Set up Lazy.nvim
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
	{'romgrk/barbar.nvim', build = ':UpdateRemotePlugins'},
	'vim-autoformat/vim-autoformat',
	{'nvim-lualine/lualine.nvim', dependencies = 'nvim-tree/nvim-web-devicons'},
	{'nvim-tree/nvim-tree.lua', dependencies = 'nvim-tree/nvim-web-devicons'},
	{
		'goolord/alpha-nvim',
		event = "VimEnter",
		dependencies = { 'nvim-tree/nvim-web-devicons' },
	},
	'ollykel/v-vim',
})
require("todo-comments").setup()
-- General setup
vim.cmd[[
colorscheme tokyonight-night
set number
set encoding=UTF-8
set noshowmode
set shell=sh
set signcolumn
]]
require("mason").setup()
require("mason-lspconfig").setup {
	ensure_installed = { "clangd", "rust-analyzer", "vls", "lua_ls" },
}
require'alpha'.setup(require'alpha.themes.dashboard'.config)
-- UI setup
vim.cmd[[nnoremap <leader>sf :NvimTreeToggle<CR>]]
require("mini.starter").setup()
require("mini.pairs").setup()
require("lualine").setup()
-- Language server setup
require("trouble").setup()
require("todo-comments").setup()
require("rust-tools").setup()
require("barbecue.ui").toggle(true)
require('lspconfig').clangd.setup {}
require('lspconfig').vls.setup {}
require('lspconfig').lua_ls.setup {}
require('lspconfig')['rust-analyzer'].setup {} -- HACK: This needs to be fixed in Lua.
require('nvim-treesitter.configs').setup {
	auto_install = true,
	highlight = {
		enable = true,
		additional_vim_regex_highlighting=false,
	},
	ident = { enable = true },
	rainbow = {
		enable = true,
		extended_mode = true,
		max_file_lines = nil,
	}
}
-- Neovim CMP
local cmp = require'cmp'
local lspkind = require'lspkind'
vim.o.guifont = "Agave Nerd Font:style=Bold:h14"
cmp.setup({
	snippet = {
		expand = function(args)
			-- For `ultisnips` user.
			vim.fn["UltiSnips#Anon"](args.body)
		end,
	},
	mapping = cmp.mapping.preset.insert({
		['<Tab>'] = function(fallback)
			if cmp.visible() then
				cmp.select_next_item()
			else
				fallback()
			end
		end,
		['<S-Tab>'] = function(fallback)
			if cmp.visible() then
				cmp.select_prev_item()
			else
				fallback()
			end
		end,
		['<CR>'] = cmp.mapping.confirm({ select = true }),
		['<C-e>'] = cmp.mapping.abort(),
		['<Esc>'] = cmp.mapping.close(),
		['<C-d>'] = cmp.mapping.scroll_docs(-4),
		['<C-f>'] = cmp.mapping.scroll_docs(4),
	}),
	sources = {
		{ name = 'nvim_lsp' }, -- For nvim-lsp
		{ name = 'ultisnips' }, -- For ultisnips user.
		{ name = 'nvim_lua' }, -- for nvim lua function
		{ name = 'path' }, -- for path completion
		{ name = 'buffer', keyword_length = 4 }, -- for buffer word completion
		{ name = 'omni' },
		{ name = 'emoji', insert = true, } -- emoji completion
	},
	window = {
		completion = cmp.config.window.bordered(),
		documentation = cmp.config.window.bordered(),
	},
	completion = {
		keyword_length = 1,
		completeopt = "menu,noselect"
	},
	view = {
		entries = 'custom',
	},
	formatting = {
		format = lspkind.cmp_format({
			mode = "symbol_text",
			menu = ({
				nvim_lsp = "[LSP]",
				ultisnips = "[US]",
				nvim_lua = "[Lua]",
				path = "[Path]",
				buffer = "[Buffer]",
				emoji = "[Emoji]",
				omni = "[Omni]",
			}),
		}),
	},
})
-- Wilder
local wilder = require('wilder')
wilder.setup({modes = {':', '/', '?'}})
wilder.set_option('renderer', wilder.popupmenu_renderer(
wilder.popupmenu_palette_theme({
	highlighter = wilder.lua_fzy_highlighter(),
	left = {' ', wilder.popupmenu_devicons()},
	right = {' ', wilder.popupmenu_scrollbar()},
	-- 'single', 'double', 'rounded' or 'solid'
	-- can also be a list of 8 characters, see :h wilder#popupmenu_palette_theme() for more details
	border = 'rounded',
	max_height = '50%',      -- max height of the palette
	min_width = '50%', -- minimum height of the popupmenu, can also be a number
	min_height = '50%', -- to set a fixed height, set max_height to the same value
	prompt_position = 'bottom', -- 'top' or 'bottom' to set the location of the prompt
	reverse = 0,             -- set to 1 to reverse the order of the list, use in combination with 'prompt_position'
})
))
-- File manager
vim.g.loaded_netrw = 1
vim.g.loaded_netrwPlugin = 1

-- set termguicolors to enable highlight groups
vim.opt.termguicolors = true
require("nvim-tree").setup({
	sort_by = "case_sensitive",
	view = {
		width = 30,
	},
	renderer = {
		group_empty = true,
	},
	filters = {
		dotfiles = true,
	},
})
