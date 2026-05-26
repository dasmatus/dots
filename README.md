# tokyonight-dots

Gentoo Linux dotfiles with a [Tokyonight](https://github.com/folke/tokyonight.nvim) colorscheme, a fully automated Full Disk Encryption installer, and wallpaper sets.

## What's included

**Window managers & desktop**
- i3 — tiling WM config
- Hyprland — Wayland compositor config
- Polybar — status bar
- Picom — compositor (blur, shadows, fading)
- Rofi — application launcher & dmenu replacement

**Terminal & shell**
- Alacritty — terminal emulator
- Fish — shell (auto-starts X on tty1, starship prompt, `bat`/`eza` aliases)

**Editor**
- Neovim — lazy.nvim, LSP (Mason), nvim-cmp, LuaSnip, conform.nvim, Treesitter, rustaceanvim, Tokyonight theme

**Notifications & theming**
- Dunst — notification daemon
- GTK 2 & 3 themes
- Neofetch config

**Browser**
- Firefox `user.js` — hardened preferences
- BetterDiscord plugins

**Gentoo / Portage**
- `make.conf.intel` / `make.conf.amd` — compiler flags, USE flags, FEATURES
- `package.use/` — per-package USE flag overrides
- `local-repo/` — custom ebuilds

**Wallpapers** — five themed sets (light · storm · night · metis · misc) × three styles (abstract · minimal · os)

---

## Automated installer

One-liner that installs Gentoo with FDE from scratch:

```bash
curl -fsSL https://gitlab.com/TenTypekMatus/tokyonight-dots/-/raw/main/install.sh | bash
```

**What it does:**

| Step | Detail |
|------|--------|
| Partitioning | GPT — 512 MiB EFI (FAT32) + LUKS2 partition |
| Filesystem | btrfs with `@root`, `@home`, `@snapshots` subvolumes |
| Encryption | LUKS2 (`cryptsetup luksFormat`) |
| Bootloader | Limine (EFI-native, no BIOS/MBR) |
| Init system | OpenRC + elogind |
| Profile | `local:default/linux/amd64/23.0/desktop/llvm/ccache` |
| WMs | i3 + Hyprland |
| Dotfiles | cloned to `~/dots` and synced automatically |

**Requirements:** UEFI firmware, root access, and a live environment with `sgdisk cryptsetup mkfs.fat mkfs.btrfs btrfs curl` (the Gentoo admin LiveCD works out of the box).

---

## Manual dotfile sync

After cloning to `~/dots`, copy configs with:

```bash
# Per-app configs → ~/.config/
for dir in alacritty dunst fish hypr i3 nvim polybar rofi neofetch gtk-2.0 gtk-3.0; do
  cp -r "Configuration files/$dir" ~/.config/
done
cp "Configuration files/picom.conf" ~/.config/picom/picom.conf

# Portage (Intel — swap .amd for AMD machines)
cp "Gentoo configuration/make.conf.intel" /etc/portage/make.conf
cp -r "Gentoo configuration/package.use/." /etc/portage/package.use/

# Local ebuild repo
cp -r "Gentoo configuration/local-repo/." /var/db/repos/local/

# Brave system policies (optional)
cp -r "Configuration files/brave/policies/" /etc/brave/policies/
```

---

## Neovim structure

```
nvim/
├── init.lua               — entry point, lazy.nvim bootstrap
└── lua/nvimcfg/
    ├── plugins.lua        — plugin registry
    ├── appearance/        — airline, nvim-tree, tabs, wilder
    ├── editor/            — keybinds, options, persistence, toggleterm, discord RPC
    └── language/          — LSP, Mason, nvim-cmp, LuaSnip, conform, Treesitter, Ansible
```

Leader key: `\`

---

## Portage variants

Two `make.conf` files are kept in sync — only the architecture-specific parts differ:

| File | CPU flags | GPU |
|------|-----------|-----|
| `make.conf.intel` | `-march=skylake` | `VIDEO_CARDS="intel i915"` |
| `make.conf.amd` | AMD equivalent | AMD/AMDGPU |

When changing shared USE flags, update both files.
