# nixvim port of files/nvim (lazy.nvim). Mason is gone: LSP servers and
# formatters come from nixpkgs. LSP uses the current `lsp` + `plugins.lspconfig`
# modules (migrated off the deprecated `plugins.lsp`) with a broad curated
# server set so common filetypes have their server in the closure already.
# Deliberate deviations from the lua config:
# TroubleToggle → Trouble v3 command; nvim-tabline (unpackaged) → bufferline
# in tabs mode; the rainbow treesitter module (dead upstream) →
# rainbow-delimiters; vls dropped (no nixpkgs package); the never-installed
# cmp omni/emoji sources and the unconfigured nvim-lint dropped.
{ pkgs, ... }:
{
  programs.nixvim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
    luaLoader.enable = true;
    # reuse the host pkgs — keeps the system allowUnfreePredicate
    # (presence.nvim) instead of nixvim instantiating its own nixpkgs
    nixpkgs.useGlobalPackages = true;

    globals = {
      mapleader = "\\";
      maplocalleader = " ";
      loaded_netrw = 1;
      loaded_netrwPlugin = 1;
      loaded_matchit = 1;
      loaded_matchparen = 1;
      ansible_ftdetect_filename_regex = "\\v(playbook|site|main|local|requirements)\\.ya?ml$";
      ansible_template_syntaxes = {
        "*.rb.j2" = "ruby";
        "*.yml.j2" = "yaml";
      };
      ansible_loop_keywords_highlight = "Constant";
      ansible_normal_keywords_highlight = "Constant";
      ansible_extra_keywords_highlight = 1;
      ansible_yamlKeyName = "yamlKey";
    };

    opts = {
      number = true;
      showmode = false;
      shell = "fish";
      signcolumn = "yes";
      guifont = "Lilex Nerd Font:style=Bold:h14";
      termguicolors = true;
      showtabline = 1;
    };

    colorschemes.tokyonight = {
      enable = true;
      settings.style = "night";
    };

    keymaps = [
      {
        mode = "n";
        key = "<space>sf";
        action = "<cmd>NvimTreeToggle<CR>";
      }
      {
        mode = "n";
        key = "<space>tn";
        action = "<cmd>tabnew<CR>";
      }
      {
        mode = "n";
        key = "<space>tc";
        action = "<cmd>tabclose<CR>";
      }
      {
        mode = "n";
        key = "<space>nt";
        action = "<cmd>tabnext<CR>";
      }
      {
        mode = "n";
        key = "<space>tt";
        action = "<cmd>ToggleTerm dir=window<CR>";
      }
      {
        mode = "n";
        key = "<space>lt";
        action = "<cmd>Trouble diagnostics toggle<CR>";
      }
      {
        mode = [
          "n"
          "v"
        ];
        key = "<leader>f";
        action.__raw = ''
          function()
            require("conform").format({ async = true, lsp_format = "fallback" })
          end
        '';
        options.desc = "Format buffer";
      }
    ];

    autoCmd = [
      {
        event = "FileType";
        pattern = "toggleterm";
        callback.__raw = ''
          function()
            vim.keymap.set('t', '<Esc>', '<cmd>ToggleTerm<CR>', { buffer = true, silent = true })
          end
        '';
      }
      {
        event = "TermOpen";
        pattern = "*";
        callback.__raw = ''
          function()
            local buf = vim.api.nvim_get_current_buf()
            vim.keymap.set('t', '<Esc>', '<C-\\><C-n><cmd>close<CR>', { buffer = buf, silent = true })
          end
        '';
      }
    ];

    plugins = {
      web-devicons.enable = true;
      which-key.enable = true;
      mini-pairs.enable = true;
      mini-sessions = {
        enable = true;
        settings.hooks.pre.write.__raw = ''
          function() vim.api.nvim_exec_autocmds('User', { pattern = 'SessionSavePre' }) end
        '';
      };

      # nvim-lspconfig plugin only. Server configs + activation live in the
      # top-level `lsp` module below (nixvim split `plugins.lsp` into
      # `lsp` + `plugins.lspconfig`; enabling both triggers a warning).
      lspconfig.enable = true;
      rustaceanvim.enable = true;
      trouble.enable = true;
      todo-comments.enable = true;
      barbecue.enable = true;

      treesitter = {
        enable = true;
        settings = {
          highlight = {
            enable = true;
            additional_vim_regex_highlighting = false;
          };
          indent.enable = true;
        };
      };
      rainbow-delimiters.enable = true;

      lspkind = {
        enable = true;
        cmp.enable = true;
        settings = {
          cmp.menu = {
            nvim_lsp = "[LSP]";
            luasnip = "[Snip]";
            nvim_lua = "[Lua]";
            path = "[Path]";
            buffer = "[Buffer]";
          };
          mode = "symbol_text";
        };
      };
      luasnip = {
        enable = true;
        fromVscode = [ { } ];
      };
      friendly-snippets.enable = true;
      cmp = {
        enable = true;
        settings = {
          snippet.expand = "function(args) require('luasnip').lsp_expand(args.body) end";
          mapping = {
            "<Tab>".__raw = ''
              function(fallback)
                local cmp = require('cmp')
                local luasnip = require('luasnip')
                if cmp.visible() then
                  cmp.select_next_item()
                elseif luasnip.expand_or_jumpable() then
                  luasnip.expand_or_jump()
                else
                  fallback()
                end
              end
            '';
            "<S-Tab>".__raw = ''
              function(fallback)
                local cmp = require('cmp')
                local luasnip = require('luasnip')
                if cmp.visible() then
                  cmp.select_prev_item()
                elseif luasnip.jumpable(-1) then
                  luasnip.jump(-1)
                else
                  fallback()
                end
              end
            '';
            "<CR>" = "cmp.mapping.confirm({ select = true })";
            "<C-e>" = "cmp.mapping.abort()";
            "<Esc>" = "cmp.mapping.close()";
            "<C-d>" = "cmp.mapping.scroll_docs(-4)";
            "<C-f>" = "cmp.mapping.scroll_docs(4)";
          };
          sources = [
            { name = "nvim_lsp"; }
            { name = "luasnip"; }
            { name = "nvim_lua"; }
            { name = "path"; }
            {
              name = "buffer";
              keyword_length = 4;
            }
            { name = "crates"; }
          ];
          window = {
            completion.__raw = "require('cmp.config.window').bordered()";
            documentation.__raw = "require('cmp.config.window').bordered()";
          };
          completion = {
            keyword_length = 1;
            completeopt = "menu,noselect";
          };
          view.entries = "custom";
          performance.fetching_timeout = 2000;
        };
      };

      dap.enable = true;
      dap-ui.enable = true;

      conform-nvim = {
        enable = true;
        settings = {
          formatters_by_ft = {
            lua = [ "stylua" ];
            rust = [ "rustfmt" ];
            c = [ "clang_format" ];
            cpp = [ "clang_format" ];
            nix = [ "nixfmt" ];
            yaml = [ "prettier" ];
            json = [ "prettier" ];
            markdown = [ "prettier" ];
            javascript = [ "prettier" ];
            typescript = [ "prettier" ];
          };
          format_on_save = {
            timeout_ms = 500;
            lsp_format = "fallback";
          };
        };
      };

      fugitive.enable = true;
      crates.enable = true;

      wilder = {
        enable = true;
        settings.modes = [
          ":"
          "/"
          "?"
        ];
      };
      lualine.enable = true;
      bufferline = {
        enable = true;
        settings.options.mode = "tabs";
      };
      nvim-tree = {
        enable = true;
        settings = {
          sort_by = "case_sensitive";
          view.width = 30;
          renderer.group_empty = true;
          filters.dotfiles = true;
        };
      };

      toggleterm = {
        enable = true;
        settings = {
          direction = "float";
          float_opts = {
            border = "curved";
            width = 90;
            height = 30;
            winblend = 4;
          };
        };
      };

      presence = {
        enable = true;
        settings = {
          auto_update = true;
          neovim_image_text = "The One True Text Editor";
          main_image = "neovim";
          client_id = "793271441293967371";
          debounce_timeout = 10;
          enable_line_number = false;
          blacklist = [ ];
          buttons = true;
          file_assets = { };
          show_time = true;
          editing_text = "Editing %s";
          file_explorer_text = "Browsing %s";
          git_commit_text = "Committing changes";
          plugin_manager_text = "Managing plugins";
          reading_text = "Reading %s";
          workspace_text = "Working on %s";
          line_number_text = "Line %s out of %s";
        };
      };

      dashboard = {
        enable = true;
        settings = {
          theme = "hyper";
          config = {
            week_header.enable = true;
            shortcut = [
              {
                desc = "󰊳 Update";
                group = "@property";
                action = "NixvimUpdate";
                key = "u";
              }
              {
                icon = " ";
                icon_hl = "@variable";
                desc = "Files";
                group = "Label";
                action = "NvimTreeOpen .";
                key = "f";
              }
              {
                desc = "Projects";
                group = "DiagnosticHint";
                action = "NvimTreeOpen ~/Dokumente";
                key = "p";
              }
            ];
          };
        };
      };

      auto-save.enable = true;
    };

    # LSP servers via nixvim's top-level `lsp` module (drives Neovim 0.11+
    # `vim.lsp.enable()` / `vim.lsp.config()`). "Auto-install" here is
    # declarative: each enabled server's nixpkgs package is already in the
    # Neovim closure, so opening a filetype just works — no Mason, no runtime
    # downloads. Rust is handled by rustaceanvim above, not listed here.
    # Keymaps stay empty (parity with the prior `plugins.lsp` config, which
    # also set none); add `lsp.keymaps` for gd/gr/K/rename bindings.
    lsp.servers = {
      clangd.enable = true;
      nil_ls.enable = true;
      lua_ls.enable = true;
      ansiblels = {
        enable = true;
        package = pkgs.ansible-language-server;
      };

      pyright.enable = true;
      ruff.enable = true;
      ts_ls.enable = true;
      gopls.enable = true;
      bashls.enable = true;
      yamlls.enable = true;
      jsonls.enable = true;
      taplo.enable = true;
      html.enable = true;
      cssls.enable = true;
      marksman.enable = true;
      texlab.enable = true;
      dockerls.enable = true;
      vimls.enable = true;
    };

    extraPlugins = with pkgs.vimPlugins; [
      ansible-vim
      (pkgs.vimUtils.buildVimPlugin {
        pname = "v-vim";
        version = "2024-unstable";
        src = pkgs.fetchFromGitHub {
          owner = "ollykel";
          repo = "v-vim";
          rev = "1dc1388bafb89072f8349dbd96f9462ae22237cb";
          hash = "sha256-AJqSUK05pq//0Nw331oTRUUrm/sO8eInTRYgvDM3i+w=";
        };
      })
    ];

    extraPackages = with pkgs; [
      curl
      lazygit
      stylua
      clang-tools
      nixfmt
      prettier
      rustfmt
    ];

    extraConfigLua = ''
      vim.opt.sessionoptions:append('globals')

      local Terminal = require('toggleterm.terminal').Terminal
      local lazygit = Terminal:new({ cmd = "lazygit", hidden = true })
      function _lazygit_toggle()
        lazygit:toggle()
      end
    '';
  };
}
