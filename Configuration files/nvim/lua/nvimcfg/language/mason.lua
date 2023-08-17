require("mason").setup()
require("mason-lspconfig").setup {
	ensure_installed = { "clangd", "rust_analyzer", "vls", "lua_ls" },
}

