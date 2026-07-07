vim.cmd[[
let g:ansible_ftdetect_filename_regex = '\v(playbook|site|main|local|requirements)\.ya?ml$'
let g:ansible_template_syntaxes = { 
	'*.rb.j2': 'ruby'
	'*.yml.j2': 'yml'
}
let g:ansible_loop_keywords_highlight = 'Constant'
let g:ansible_normal_keywords_highlight = 'Constant'
let g:ansible_extra_keywords_highlight = 1
let g:ansible_yamlKeyName = 'yamlKey'
]]
