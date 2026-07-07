require("conform").setup({
	formatters_by_ft = {
		lua        = { "stylua" },
		rust       = { "rustfmt", lsp_format = "fallback" },
		c          = { "clang_format" },
		cpp        = { "clang_format" },
		nix        = { "nixfmt" },
		yaml       = { "prettier" },
		json       = { "prettier" },
		markdown   = { "prettier" },
		javascript = { "prettier" },
		typescript = { "prettier" },
	},
	format_on_save = {
		timeout_ms = 500,
		lsp_format = "fallback",
	},
})

vim.keymap.set({ "n", "v" }, "<leader>f", function()
	require("conform").format({ async = true, lsp_format = "fallback" })
end, { desc = "Format buffer" })
