# tokyonight-dots

A [Tokyonight](https://github.com/folke/tokyonight.nvim)-themed **NixOS flake**:
system config for two hosts (`tokyonight-intel`, `tokyonight-amd`), a
home-manager profile, and a LiveISO carrying a ratatui-based installer.

## Quickstart

```bash
# From any Linux with nix installed: builds + runs the installer TUI
curl -fsSL https://gitlab.com/TenTypekMatus/tokyonight-dots/-/raw/main/install.sh | bash

# Equivalent, from a checkout:
nix run .#dots-installer

# Or build a bootable LiveISO instead (installer auto-starts on tty1):
nix build .#iso
dd if=result/iso/*.iso of=/dev/sdX bs=4M oflag=sync

# On an already-installed system, apply config changes:
sudo nixos-rebuild switch --flake .#tokyonight-amd   # or #tokyonight-intel
```

`installer-tui/` (package name `dots-installer`) is a Rust/ratatui wizard —
disk picker → intel/amd variant → hostname → user → passwords → typed-`ERASE`
confirm — that runs [disko](https://github.com/nix-community/disko),
`nixos-install` from the flake bundled on the ISO, enrolls TPM2 (PCR 7) + a
printed LUKS recovery key, and reboots. Dev loop:

```bash
just nix-lint    # nix flake check + cargo fmt/clippy/test
just iso         # build the LiveISO
just nix-smoke   # boot it in the OVMF+swtpm harness, assert the TUI starts
```

## Declarative flatpaks

`nix/modules/flatpak.nix` rebuilds `/var/lib/flatpak` from a pinned package
list on every activation (and weekly) — anything installed imperatively,
including via GNOME Software (left disabled), gets wiped on the next run.
Two things worth knowing before the first switch:

- **GNOME core apps** (Calculator, Maps, Text Editor, …) are sourced from a
  verified Flathub subset rather than nixpkgs; `services.gnome.core-apps` is
  off in `nix/modules/desktop.nix` to avoid duplicates.
- The **first** `nixos-rebuild switch` downloads roughly 50 Flatpak apps
  (verified subset + a few unverified ones + a pinned Haveno release
  bundle) — expect it to take a while on a fresh install.
- If you're migrating from an imperative Flatpak setup, run
  `flatpak uninstall --user --all` first — user-level installs shadow the
  system-level declarative ones and duplicate entries in app launchers.

## Home-manager highlights

- **nixvim** (`nix/home/nixvim.nix`) — a from-scratch port of the old
  lazy.nvim config: LSP via nixpkgs packages (no Mason), Treesitter,
  rainbow-delimiters, bufferline, Tokyonight theme.
- **Wayland-only Hyprland session** — `nix/home/hyprland.nix` +
  `waybar.nix` + `dunst.nix` + `rofi/` provide the compositor, bar,
  notifications and launcher; `services.hypridle` / `programs.hyprlock` /
  `services.gammastep` replace the old swayidle/swaylock/redshift
  exec-once lines. No X11 session remains.
- **LibreWolf** (`nix/home/librewolf.nix`) — runs as a flatpak with an
  arkenfox-derived `user.js` layered on top of LibreWolf's own hardened
  defaults, declaratively injected into the flatpak's persisted profile.
- **haumea `~/Dokumente` skeleton** (`nix/home/dokumente.nix` +
  `nix/home/dokumente/`) — the directory tree under `dokumente/` *is* the
  data; haumea loads it and home-manager activation `mkdir -p`s every leaf
  into `~/Dokumente` on login, idempotently.
- **Wallhaven wallpaper service** (`nix/home/random_wp.nix`) — a user
  timer that pulls a random wallpaper from the Wallhaven API on login and
  hourly, applied via `swaybg` under Hyprland or `gsettings` under GNOME.

## Testing

```bash
just nix-lint    # nix flake check + installer-tui cargo fmt/clippy/test
just iso         # build the LiveISO
just nix-smoke   # boot the ISO under OVMF+swtpm, assert the TUI reaches tty1
```

See [`tests/README.md`](tests/README.md) for how the VM harness works.

## Layout

| Path | What |
|------|------|
| `flake.nix` | Inputs, `nixosConfigurations`, `packages.dots-installer`, formatter |
| `nix/settings.nix` | Install-time parameters (username, hostname, disk, swap) |
| `nix/disko.nix` | Single source of truth for the disk layout |
| `nix/hosts/{amd,intel}.nix` | Per-CPU-vendor deltas (microcode, GPU) |
| `nix/modules/` | System configuration split by concern (boot, core, desktop, flatpak, hardening, maintenance, network, secureboot, users, virtualisation) |
| `nix/home/` | home-manager profile (nixvim, Hyprland session, LibreWolf, Dokumente skeleton, wallpaper service) |
| `nix/iso.nix` | The LiveISO: embeds the flake at `/etc/dots`, auto-launches `dots-installer` on tty1 |
| `installer-tui/` | The Rust/ratatui installer source |
| `Wallpapers/` | Five themed sets (light · storm · night · metis · misc) × three styles (abstract · minimal · os) |

See [`nix/README.md`](nix/README.md) for the full module-by-module design
notes (including what this repo's retired Gentoo installer used to do, for
history).
