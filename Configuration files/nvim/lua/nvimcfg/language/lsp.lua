require("trouble").setup()
require("todo-comments").setup()
require("rust-tools").setup()
require("barbecue.ui").toggle(true)
require('lspconfig').clangd.setup {}
require('lspconfig').vls.setup {}
require('lspconfig').lua_ls.setup {}
require('lspconfig').nil_ls.setup {}
require('lspconfig').ansiblels.setup {}
require('lspconfig')['rust_analyzer'].setup {} -- HACK: This needs to be fixed in Lua.
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
