# tokyonight-dots

A [Tokyonight](https://github.com/folke/tokyonight.nvim)-themed NixOS flake. One
`tokyonight` system config, hardware detection through
[nixos-facter](https://github.com/nix-community/nixos-facter), a home-manager
profile, and a LiveISO that carries a ratatui installer.

## Quickstart

```bash
# From any Linux with nix installed: builds + runs the installer TUI
curl -fsSL https://gitlab.com/TenTypekMatus/tokyonight-dots/-/raw/main/install.sh | bash

# Equivalent, from a checkout:
nix run .#dots-installer

# Or build a bootable LiveISO instead (installer auto-starts on tty1;
# plain and unsigned, so it boots via firmware defaults, no Secure Boot):
nix run .#iso
dd if=result-iso/iso/*.iso of=/dev/sdX bs=4M oflag=sync

# On an already-installed system, apply config changes:
sudo nixos-rebuild switch --flake .#tokyonight
```

`rust/installer-tui/` (package name `dots-installer`) is a Rust/ratatui wizard.
It walks disk autodetection, hostname, user and password, then makes you type
`ERASE` before it touches the disk. After that it runs
[disko](https://github.com/nix-community/disko), generates a
[nixos-facter](https://github.com/nix-community/nixos-facter) hardware report on
the target so nobody has to pick intel vs amd by hand, runs `nixos-install` from
the flake bundled on the ISO, enrolls TPM2 against PCR 7 next to a printed LUKS
recovery key, and reboots.

## Declarative flatpaks

`nix/modules/flatpak.nix` rebuilds `/var/lib/flatpak` from a pinned package list
on every activation, and again weekly. Anything installed imperatively gets
wiped on the next run, GNOME Software included, which is why that one ships
disabled. Destroying imperative state is the point of the module, but it still
catches you out the first time.

Three things worth knowing before the first switch:

- GNOME core apps (Calculator, Maps, Text Editor and the rest) come from a
  verified Flathub subset instead of nixpkgs. `services.gnome.core-apps` is off
  in `nix/modules/desktop.nix` so you don't end up with two of everything.
- The first `nixos-rebuild switch` pulls roughly 50 Flatpak apps: the verified
  subset, a few unverified ones, and a pinned Haveno release bundle. On a fresh
  install, go make coffee.
- Coming from an imperative Flatpak setup? Run `flatpak uninstall --user --all`
  first. User-level installs shadow the system-level declarative ones, and you
  get duplicate entries in every launcher.

## Home-manager highlights

- **nixvim** (`nix/home/nixvim.nix`). A from-scratch port of the old lazy.nvim
  config. LSP servers come from nixpkgs, so there is no Mason. Treesitter,
  rainbow-delimiters, bufferline, Tokyonight theme.
- **Wayland-only Hyprland session**. `nix/home/hyprland.nix`, `waybar.nix`,
  `dunst.nix` and `hyprtile.nix` give you the compositor, bar, notifications and
  the [HyprTile](https://hyprtile.org/) fullscreen tile launcher on SUPER+D.
  Page 2 of the launcher is the power menu, `hyprtile-shotter` handles Print-key
  screenshots, `hyprtile-wallpaperd` draws the wallpaper, and
  `hyprtile-sync-apps` regenerates pages 3 and up from every installed
  `.desktop` entry. The suite builds from source as the flake package
  `hyprtile`, patched to act like rofi: floating pinned overlay, dismissed on
  focus loss. `services.hypridle`, `programs.hyprlock` and `services.gammastep`
  replace the old swayidle/swaylock/redshift exec-once lines. No X11 session is
  left anywhere.
- **LibreWolf** (`nix/home/librewolf.nix`). Runs as a flatpak with an
  arkenfox-derived `user.js` layered over LibreWolf's own hardened defaults,
  injected declaratively into the flatpak's persisted profile.
- **haumea `~/Dokumente` skeleton** (`nix/home/dokumente.nix` and
  `nix/home/dokumente/`). The directory tree under `dokumente/` *is* the data.
  haumea loads it, and home-manager activation `mkdir -p`s every leaf into
  `~/Dokumente` on login, idempotently.
- **Wallhaven wallpaper service** (`nix/home/random_wp.nix`). A user timer that
  pulls a random wallpaper from the Wallhaven API on login and every hour after,
  applied through `wallpaper-tui`/`hyprtile-wallpaperd` under Hyprland or
  `gsettings` under GNOME.

## Testing

```bash
nix run .#nix-lint    # nix flake check (eval) + rust/* cargo fmt/clippy/test
nix run .#iso         # build the LiveISO (plain, unsigned)
nix run .#nix-smoke   # NixOS VM test: boot the ISO under OVMF+TPM2, assert TUI ready
```

`nix-smoke` is the one that matters before you trust a change to the install
path. It boots the built ISO in a VM and waits for the installer to signal that
it came up.

See [`tests/README.md`](tests/README.md) for how the NixOS VM tests work.

## Layout

| Path | What |
|------|------|
| `flake.nix` | Inputs, `nixosConfigurations`, `packages.dots-installer`, formatter |
| `nix/settings.nix` | Install-time parameters (username, hostname, disk, swap) |
| `nix/disko.nix` | Single source of truth for the disk layout |
| `nix/hosts.nix` | facter-driven hardware config (NVIDIA via if-then-else on the report) |
| `nix/facter.json` | Committed stub (`{}`); the installer writes the real report on the target |
| `nix/modules/` | System configuration split by concern (boot, core, desktop, flatpak, hardening, maintenance, network, users, virtualisation) |
| `nix/home/` | home-manager profile (nixvim, Hyprland session, LibreWolf, Dokumente skeleton, wallpaper service) |
| `nix/iso.nix` | The LiveISO: embeds the flake at `/etc/dots`, auto-launches `dots-installer` on tty1 |
| `rust/installer-tui/` | The Rust/ratatui installer source |
| `Wallpapers/` | Five themed sets (light · storm · night · metis · misc) × three styles (abstract · minimal · os) |

[`nix/README.md`](nix/README.md) has the module-by-module design notes, including
what this repo's retired Gentoo installer used to do, kept around for history.
