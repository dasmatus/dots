# tokyonight-dots

A [Tokyonight](https://github.com/folke/tokyonight.nvim)-themed **NixOS flake**:
a single `tokyonight` system config with
[nixos-facter](https://github.com/nix-community/nixos-facter)-based hardware
detection, a home-manager profile, and a LiveISO carrying a ratatui-based
installer.

## Quickstart

```bash
# From any Linux with nix installed: builds + runs the installer TUI
curl -fsSL https://gitlab.com/TenTypekMatus/tokyonight-dots/-/raw/main/install.sh | bash

# Equivalent, from a checkout:
nix run .#dots-installer

# Or build a bootable LiveISO instead (installer auto-starts on tty1;
# signed for Secure Boot by default — see nix/README.md):
just iso
dd if=result-iso-signed/*.iso of=/dev/sdX bs=4M oflag=sync

# On an already-installed system, apply config changes:
sudo nixos-rebuild switch --flake .#tokyonight
```

`installer-tui/` (package name `dots-installer`) is a Rust/ratatui wizard —
disk picker → hostname → user → passwords → typed-`ERASE` confirm — that runs
[disko](https://github.com/nix-community/disko), generates a
[nixos-facter](https://github.com/nix-community/nixos-facter) hardware report
on the target (no more manual intel/amd picking), runs `nixos-install` from
the flake bundled on the ISO, enrolls TPM2 (PCR 7) + a printed LUKS recovery
key, and reboots. Dev loop:

```bash
just nix-lint    # nix flake check (eval) + cargo fmt/clippy/test
just iso         # build the LiveISO + sign it for Secure Boot
just nix-smoke   # NixOS VM test: boot it under Secure Boot-enforcing OVMF+TPM2
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
just nix-lint    # nix flake check (eval) + installer-tui cargo fmt/clippy/test
just iso         # build the LiveISO + sign it for Secure Boot
just nix-smoke   # NixOS VM test: boot the signed ISO under Secure
                 # Boot-enforcing OVMF+TPM2, assert TUI + SecureBoot=1
```

See [`tests/README.md`](tests/README.md) for how the NixOS VM tests work.

## Layout

| Path | What |
|------|------|
| `flake.nix` | Inputs, `nixosConfigurations`, `packages.dots-installer`, formatter |
| `nix/settings.nix` | Install-time parameters (username, hostname, disk, swap) |
| `nix/disko.nix` | Single source of truth for the disk layout |
| `nix/hosts.nix` | facter-driven hardware config (NVIDIA via if-then-else on the report) |
| `nix/facter.json` | Committed stub (`{}`); the installer writes the real report on the target |
| `nix/modules/` | System configuration split by concern (boot, core, desktop, flatpak, hardening, maintenance, network, secureboot, users, virtualisation) |
| `nix/home/` | home-manager profile (nixvim, Hyprland session, LibreWolf, Dokumente skeleton, wallpaper service) |
| `nix/iso.nix` | The LiveISO: embeds the flake at `/etc/dots`, auto-launches `dots-installer` on tty1 |
| `installer-tui/` | The Rust/ratatui installer source |
| `Wallpapers/` | Five themed sets (light · storm · night · metis · misc) × three styles (abstract · minimal · os) |

See [`nix/README.md`](nix/README.md) for the full module-by-module design
notes (including what this repo's retired Gentoo installer used to do, for
history).
