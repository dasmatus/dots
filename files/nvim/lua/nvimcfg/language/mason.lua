require("mason").setup()
require("mason-lspconfig").setup {
	ensure_installed = { "clangd", "rust_analyzer", "nil_ls", "vls", "lua_ls", "ansiblels" },
	automatic_installation = true,
	handlers = {
		function(server_name)
			require("lspconfig")[server_name].setup {}
		end,
		["rust_analyzer"] = function() end,
	},
}
