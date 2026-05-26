vim.loader.enable()                   -- Bytecode cache: must be first
vim.g.loaded_netrw = 1               -- Disable netrw before plugins load
vim.g.loaded_netrwPlugin = 1
vim.g.loaded_matchit = 1             -- Disable unused built-ins
vim.g.loaded_matchparen = 1

require("nvimcfg.plugins")           -- Plugin registry + lazy loading
require('nvimcfg.editor.keybinds')   -- Key bindings
require('nvimcfg.editor.opts')       -- Vim options
