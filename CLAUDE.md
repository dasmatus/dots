# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Gentoo Linux dotfiles repository ("tokyonight-dots") containing:
- **`files/`** — user configs copied to `~/.config/` (alacritty, dunst, fish, hypr, i3, nvim, polybar, rofi, neofetch, gtk-2.0, gtk-3.0, picom.conf)
- **`Gentoo configuration/`** — Portage configs (`make.conf.amd`, `make.conf.intel`, `package.use/`, `local-repo/`)
- **`install.sh`** — A fully automated Gentoo FDE installer (LUKS2 + dm-integrity → btrfs, `systemd-repart` declarative partitioning, systemd-boot + UKI, systemd init, `systemd-sysupdate` A/B UKI updates, `systemd-homed` first-boot user, i3 + Hyprland). Requires a **systemd-based** live env with `cargo`.
- **`.steps.yaml`** — afosi (`agent-first-os-installer`) config: the install-time user prompts (disk, hostname, root password, wipe confirm). `install.sh` builds the `installer` binary and hands off to it; its final action re-enters `install.sh` with answers in the env (`AFOSI_DRIVEN=1`).
- **`.konkrit.yaml`** — konkrit hardening catalog (100+ modules) + Alpine/QEMU Flatpak VM, run on **first boot**. Generated via `konkrit catalog`, then **adapted Arch→Gentoo** (pacman→emerge, mkinitcpio/sbctl/grub→`rebuild-uki`, `/etc/cmdline.d`→`/etc/kernel/cmdline.d`, hardened_malloc→`dev-libs/hardened_malloc` from GURU, apparmor.d→`sec-policy/apparmor-profiles`, linux-hardened disabled). `{{user}}` is set by the first-boot service. See the adaptation banner atop the file; keep it accurate if you re-generate.
- **`Wallpapers/`** — Themed wallpaper sets (light/storm/night/metis/misc × abstract/minimal/os)
- **`user.js`** — Firefox user.js hardening preferences

## Agent-first tooling (afosi + konkrit)

Two Rust crates from the `agents-make-an-os` family are built from source (`cargo`) during install:
- **afosi** builds in the **live env**; its `.steps.yaml` is validated by regenerating structure with `installer emit-cfg` and editing only values. Forms are `!Input`/`!YesNo`/`!Choice`; all answers are exported as env vars to the final `!action` that runs `bash /root/install.sh`.
- **konkrit** builds in the **installed system** (chroot), runs on first boot. Both tools **dry-run in debug builds, execute in release** — `cargo install` produces release binaries. konkrit **aborts its whole run if a step's program is missing** (e.g. `pacman` on Gentoo), so the first-boot call is guarded with `|| warn` and never blocks boot.

## Deployment

The installer is designed to run from a Gentoo live environment:
```bash
curl -fsSL https://gitlab.com/TenTypekMatus/tokyonight-dots/-/raw/main/install.sh | bash
```

After installation, dotfiles are cloned to `~/dots` and synced automatically by the installer. For manual dotfile sync, the installer copies:
- `files/<dir>` → `~/.config/<dir>` for each of: alacritty, dunst, fish, hypr, i3, nvim, polybar, rofi, neofetch, gtk-2.0, gtk-3.0
- `files/picom.conf` → `~/.config/picom/picom.conf`
- `Gentoo configuration/make.conf.intel` (or `.amd`) → `/etc/portage/make.conf`
- `Gentoo configuration/package.use/*` → `/etc/portage/package.use/`
- `files/brave/policies/` → `/etc/brave/policies/` (system-wide)
- `Gentoo configuration/local-repo/` → `/var/db/repos/local/` + `repos.conf/local.conf` + profile set to `local:default/linux/amd64/23.0/desktop/llvm/ccache`

## Architecture decisions

- **Two make.conf variants**: `make.conf.intel` (skylake `-march`, `VIDEO_CARDS="intel i915"`) and `make.conf.amd` — keep them in sync when changing shared USE flags
- **Neovim config** uses lazy.nvim with modules split under `lua/nvimcfg/`: `plugins.lua` registers all plugins; `language/`, `appearance/`, `editor/` subdirs configure them. Leader key is `\`
- **Fish** auto-starts X on tty1 login (`startx`), uses starship prompt, aliases `cat`→`bat` and `ls`→`eza`
- **`.gitignore`** explicitly ignores `files/brave/` (contains personal browser profile data) and `.codegraph/`

## Theme

All configs use the **Tokyonight** colorscheme. When adding or modifying config files, maintain Tokyonight color consistency across components.
