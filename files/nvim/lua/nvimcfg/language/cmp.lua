local cmp = require('cmp')
local luasnip = require('luasnip')
local lspkind = require('lspkind')

cmp.setup({
	snippet = {
		expand = function(args)
			luasnip.lsp_expand(args.body)
		end,
	},
	mapping = cmp.mapping.preset.insert({
		['<Tab>'] = function(fallback)
			if cmp.visible() then
				cmp.select_next_item()
			elseif luasnip.expand_or_jumpable() then
				luasnip.expand_or_jump()
			else
				fallback()
			end
		end,
		['<S-Tab>'] = function(fallback)
			if cmp.visible() then
				cmp.select_prev_item()
			elseif luasnip.jumpable(-1) then
				luasnip.jump(-1)
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
		{ name = 'nvim_lsp' },
		{ name = 'luasnip' },
		{ name = 'nvim_lua' },
		{ name = 'path' },
		{ name = 'buffer', keyword_length = 4 },
		{ name = 'omni' },
		{ name = 'emoji', insert = true },
		{ name = 'crates' },
	},
	window = {
		completion = cmp.config.window.bordered(),
		documentation = cmp.config.window.bordered(),
	},
	completion = {
		keyword_length = 1,
		completeopt = "menu,noselect",
	},
	view = {
		entries = 'custom',
	},
	formatting = {
		format = lspkind.cmp_format({
			mode = "symbol_text",
			menu = ({
				nvim_lsp = "[LSP]",
				luasnip  = "[Snip]",
				nvim_lua = "[Lua]",
				path     = "[Path]",
				buffer   = "[Buffer]",
				emoji    = "[Emoji]",
				omni     = "[Omni]",
			}),
		}),
	},
})
