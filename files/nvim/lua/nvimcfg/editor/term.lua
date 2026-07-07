-- Close ToggleTerm with Escape (buffer-local, set when the filetype loads)
vim.api.nvim_create_autocmd("FileType", {
  pattern = "toggleterm",
  callback = function()
    vim.keymap.set('t', '<Esc>', '<cmd>ToggleTerm<CR>', { buffer = true, silent = true })
  end,
})

-- Exit and close native terminal windows with Escape
vim.api.nvim_create_autocmd("TermOpen", {
  pattern = "*",
  callback = function()
    local buf = vim.api.nvim_get_current_buf()
    vim.keymap.set('t', '<Esc>', '<C-\\><C-n><cmd>close<CR>', { buffer = buf, silent = true })
  end,
})

require('toggleterm').setup({
	direction = 'float',
	float_opts = {
		border = 'curved',
		width = 90,
		height = 30,
		winblend = 4,
	},
})

local Terminal  = require('toggleterm.terminal').Terminal
local lazygit = Terminal:new({ cmd = "lazygit", hidden = true })

function _lazygit_toggle()
  lazygit:toggle()
end
