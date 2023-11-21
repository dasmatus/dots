require("mason").setup()
require("mason-lspconfig").setup {
	ensure_installed = { "clangd", "rust_analyzer", "nil_ls", "vls", "lua_ls", "ansiblels" },
}

