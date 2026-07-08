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
| Partitioning | Declarative via `systemd-repart` — GPT, 2 GiB ESP (FAT32) + LUKS2 partition |
| Filesystem | btrfs with `@root`, `@home`, `@snapshots` subvolumes |
| Encryption | LUKS2 **+ dm-integrity** (`--integrity hmac-sha256`, authenticated) |
| Bootloader | systemd-boot + Unified Kernel Images (UKI) |
| Init system | systemd |
| Extras | `systemd-repart` · `systemd-sysupdate` (A/B UKI) · `systemd-homed` |
| Profile | `local:default/linux/amd64/23.0/desktop/llvm/ccache` (systemd parent) |
| WMs | i3 + Hyprland |
| User | created on **first boot** via `homectl` (LUKS-backed home); dotfiles from `/etc/skel` |
| Prompts | collected by the **afosi** installer (`.steps.yaml`) — builds `installer` from source in the live env |
| First boot | **konkrit** applies its hardening catalog + Alpine/QEMU Flatpak VM (`.konkrit.yaml`) |

**Requirements:** UEFI firmware, root access, and a **systemd-based** live environment (SystemRescue / Gentoo LiveGUI / Arch ISO — *not* the OpenRC admin CD) with `systemd-repart bootctl cryptsetup mkfs.btrfs btrfs curl` **and a Rust toolchain (`cargo`)** to build the afosi front-end.

### Agent-first tooling

The installer integrates two crates from the [`agents-make-an-os`](https://gitlab.com/agents-make-an-os) family — both build from source (`cargo`) during install:

- **afosi** (`agent-first-os-installer`) drives the install-time **user prompts**. `install.sh` (still `curl … | bash`) builds the `installer` binary, which reads [`.steps.yaml`](.steps.yaml) (disk, hostname, root password, wipe confirmation) and re-enters `install.sh` with the answers in the environment.
- **konkrit** runs on **first boot**: an agent-first Linux hardening catalog (100+ source-cited modules) plus an Alpine/QEMU **Flatpak VM**. The catalog in [`.konkrit.yaml`](.konkrit.yaml) has been **adapted from Arch to Gentoo** (`pacman`→`emerge` with verified atoms, `mkinitcpio`/`sbctl`/`grub`→a `rebuild-uki` helper, `/etc/cmdline.d`→`/etc/kernel/cmdline.d`, `hardened_malloc`→`dev-libs/hardened_malloc` from the **GURU overlay** which `install.sh` enables, `apparmor.d`→`sec-policy/apparmor-profiles`; the linux-hardened-kernel module is disabled). See the adaptation banner at the top of the file.
  - It still ships the **maximal secureblue-style posture** (76 modules enabled) — review `enabled:` flags and the high-risk items (e.g. the `/etc/ld.so.preload` hardened-malloc module) before first boot. The first-boot call is guarded (`|| warn`) so a konkrit failure never blocks boot.

---

## Manual dotfile sync

After cloning to `~/dots`, copy configs with:

```bash
# Per-app configs → ~/.config/
for dir in alacritty dunst fish hypr i3 nvim polybar rofi neofetch gtk-2.0 gtk-3.0; do
  cp -r "files/$dir" ~/.config/
done
cp "files/picom.conf" ~/.config/picom/picom.conf

# Portage (Intel — swap .amd for AMD machines)
cp "Gentoo configuration/make.conf.intel" /etc/portage/make.conf
cp -r "Gentoo configuration/package.use/." /etc/portage/package.use/

# Local ebuild repo
cp -r "Gentoo configuration/local-repo/." /var/db/repos/local/

# Brave system policies (optional)
cp -r "files/brave/policies/" /etc/brave/policies/
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
