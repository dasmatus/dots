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

## NixOS target (flake + LiveISO installer)

The whole system also exists as a **Nix flake**: NixOS + home-manager +
[disko](https://github.com/nix-community/disko), with the same layout the
Gentoo installer produces (2G ESP, TPM2-unlocked LUKS2 btrfs root with
`@root/@home/@snapshots/@builds` subvolumes, random-key encrypted swap) — the
sealed dm-verity `/usr` machinery is replaced by the read-only `/nix/store`
and generation rollback. See [`nix/README.md`](nix/README.md) for the full
Gentoo→NixOS mapping.

```bash
nix build .#iso                 # LiveISO with the ratatui installer on tty1
dd if=result/iso/*.iso of=/dev/sdX bs=4M oflag=sync

# on an existing NixOS install:
sudo nixos-rebuild switch --flake .#tokyonight-intel   # or #tokyonight-amd
```

The ISO auto-starts **`installer-tui/`** — a Rust/ratatui wizard (disk picker →
intel/amd variant → hostname → user → passwords → typed-`ERASE` confirm) that
runs disko, `nixos-install` from the flake bundled on the ISO, enrolls TPM2
(PCR 7) + a printed LUKS recovery key, and reboots. Dev loop:

```bash
just nix-lint    # nix flake check + cargo fmt/clippy/test
just iso         # build the LiveISO
just nix-smoke   # boot it in the OVMF+swtpm harness, assert the TUI starts
```

---

## Automated installer

One-liner that installs Gentoo with FDE from scratch:

```bash
curl -fsSL https://gitlab.com/TenTypekMatus/tokyonight-dots/-/raw/main/install.sh | bash
```

`install.sh` is a thin **curl wrapper** — the actual installer is the Python
package in [`installer/`](installer/) (stdlib only, split into modules for the
bootstrap / host / chroot phases). The wrapper runs the package in place from
a repo checkout, or fetches it to `/root/installer/` when piped from curl.
The stage3 tarball comes from the **tux.rainside.sk** mirror
(`hardened-selinux-systemd` profile); override with `STAGE3_BASE=<url>`.

**What it does:**

| Step | Detail |
|------|--------|
| Partitioning | Declarative via `systemd-repart` — GPT, 2 GiB ESP (FAT32) + LUKS2 partition |
| Filesystem | btrfs with `@root`, `@home`, `@snapshots` subvolumes |
| Encryption | LUKS2 **+ dm-integrity** (`--integrity hmac-sha256`, authenticated) |
| Bootloader | systemd-boot + Unified Kernel Images (UKI) |
| Init system | systemd |
| Extras | `systemd-repart` · `systemd-sysupdate` (A/B UKI) · `systemd-homed` |
| Packages | binary packages enabled (`getbinpkg` + official Gentoo binhost, signature-verified) to cut compile time |
| Auto-update | 6 h timer syncs the tree & flags `@world` updates; the upgrade runs in the background on **suspend** (freezes through S3, resumes on wake), then refreshes the sd-sysupdate image |
| dm-integrity | Portage builds in a **tmpfs** (`/var/tmp/portage`) + zram swap so compile I/O stays off the write-amplifying integrity root; giants fall back to disk via `package.env` |
| Profile | `local:default/linux/amd64/23.0/desktop/llvm/ccache` (systemd parent) |
| WMs | i3 + Hyprland |
| User | created on **first boot** via `homectl` (LUKS-backed home); dotfiles from `/etc/skel` |
| Prompts | collected by the **afosi** installer (`.steps.yaml`) — builds `installer` from source in the live env |
| First boot | **konkrit** applies its hardening catalog + Alpine/QEMU Flatpak VM (`.konkrit.yaml`) |

**Requirements:** UEFI firmware, root access, and a **systemd-based** live environment (SystemRescue / Gentoo LiveGUI / Arch ISO — *not* the OpenRC admin CD) with `python3 systemd-repart bootctl cryptsetup mkfs.btrfs btrfs curl` **and a Rust toolchain (`cargo`)** to build the afosi front-end.

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
