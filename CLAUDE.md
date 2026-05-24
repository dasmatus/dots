# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Gentoo Linux dotfiles repository ("tokyonight-dots") containing:
- **`Configuration files/`** — user configs copied to `~/.config/` (alacritty, dunst, fish, hypr, i3, nvim, polybar, rofi, neofetch, gtk-2.0, gtk-3.0, picom.conf)
- **`Gentoo configuration/`** — Portage configs (`make.conf.amd`, `make.conf.intel`, `package.use/`, `local-repo/`)
- **`install.sh`** — A fully automated Gentoo FDE installer (LUKS2 → btrfs, Limine EFI bootloader, OpenRC, i3 + Hyprland)
- **`Wallpapers/`** — Themed wallpaper sets (light/storm/night/metis/misc × abstract/minimal/os)
- **`user.js`** — Firefox user.js hardening preferences

## Deployment

The installer is designed to run from a Gentoo live environment:
```bash
curl -fsSL https://gitlab.com/TenTypekMatus/tokyonight-dots/-/raw/main/install.sh | bash
```

After installation, dotfiles are cloned to `~/dots` and synced automatically by the installer. For manual dotfile sync, the installer copies:
- `Configuration files/<dir>` → `~/.config/<dir>` for each of: alacritty, dunst, fish, hypr, i3, nvim, polybar, rofi, neofetch, gtk-2.0, gtk-3.0
- `Configuration files/picom.conf` → `~/.config/picom/picom.conf`
- `Gentoo configuration/make.conf.intel` (or `.amd`) → `/etc/portage/make.conf`
- `Gentoo configuration/package.use/*` → `/etc/portage/package.use/`
- `Configuration files/brave/policies/` → `/etc/brave/policies/` (system-wide)
- `Gentoo configuration/local-repo/` → `/var/db/repos/local/` + `repos.conf/local.conf` + profile set to `local:default/linux/amd64/23.0/desktop/llvm/ccache`

## Architecture decisions

- **Two make.conf variants**: `make.conf.intel` (skylake `-march`, `VIDEO_CARDS="intel i915"`) and `make.conf.amd` — keep them in sync when changing shared USE flags
- **Neovim config** uses lazy.nvim with modules split under `lua/nvimcfg/`: `plugins.lua` registers all plugins; `language/`, `appearance/`, `editor/` subdirs configure them. Leader key is `\`
- **Fish** auto-starts X on tty1 login (`startx`), uses starship prompt, aliases `cat`→`bat` and `ls`→`eza`
- **`.gitignore`** explicitly ignores `Configuration files/brave/` (contains personal browser profile data) and `.codegraph/`

## Theme

All configs use the **Tokyonight** colorscheme. When adding or modifying config files, maintain Tokyonight color consistency across components.
