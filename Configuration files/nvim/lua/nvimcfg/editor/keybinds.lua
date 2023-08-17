--  WARN: Everything must be properly aligned!!!
vim.cmd[[
nnoremap <space>sf :NvimTreeToggle	  <CR>
nnoremap <space>tn :tabnew	  	  <CR>
nnoremap <space>tc :tabclose	  	  <CR>
nnoremap <space>nt :tabnext 	  	  <CR>
nnoremap <C-t>     :ToggleTerm 	  	  <CR>
nnoremap <space>lg :lua _lazygit_toggle() <CR>
]]
