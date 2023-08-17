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
