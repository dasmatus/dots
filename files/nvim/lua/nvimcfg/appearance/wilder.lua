
-- Wilder
local wilder = require('wilder')
wilder.setup({modes = {':', '/', '?'}})
wilder.set_option('renderer', wilder.popupmenu_renderer(
wilder.popupmenu_palette_theme({
	highlighter = wilder.basic_highlighter(),
	left = {' ', wilder.popupmenu_devicons()},
	right = {' ', wilder.popupmenu_scrollbar()},
	border = 'rounded',
	max_height = '50%',      
	min_width = '50%', 
	min_height = '50%', -- to set a fixed height, set max_height to the same value
	prompt_position = 'bottom', -- 'top' or 'bottom' to set the location of the prompt
	reverse = 0,             -- set to 1 to reverse the order of the list, use in combination with 'prompt_position'
})
))
