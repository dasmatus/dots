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

## Native packages, no Flatpak

Every GUI app is a native nixpkgs package in `nix/home/base/pkgs.nix`. The repo used
to rebuild `/var/lib/flatpak` from a pinned list through `nix/modules/flatpak.nix`,
wiping anything installed imperatively on every activation. That module and the
declarative-flatpak input are both gone. The header of `nix/home/base/pkgs.nix` lists
what each app became and what got dropped on the way.

Three things worth knowing:

- GNOME core apps (Calculator, Maps, Text Editor and the rest) come from
  `services.gnome.core-apps` again, not from a verified Flathub subset.
- Haveno ships no nixpkgs package, so `pkgs.nix` wraps the release AppImage and
  cross-checks its sha256 against the release's `1.8.0-reto.hashes` file, the
  way the old flatpak bundle pin did.
- A few Flathub-only apps had no nixpkgs equivalent and did not survive the
  move. Flatseal went with the flatpaks it used to manage, and virt-manager was
  already native through `programs.virt-manager`.

## Home-manager highlights

- **nixvim** (`nix/home/apps/nixvim.nix`). A from-scratch port of the old lazy.nvim
  config. LSP servers come from nixpkgs, so there is no Mason. Treesitter,
  rainbow-delimiters, bufferline, Tokyonight theme.
- **Wayland-only Hyprland session**. `nix/home/desktop/hyprland.nix` is the compositor;
  everything drawn on top of it is one [Quickshell](https://quickshell.org)
  config in `nix/home/desktop/quickshell/`. The bar, the notification daemon, the
  volume and brightness OSD, the launcher on SUPER+Space, the keybind
  cheatsheet on SUPER+/ and the settings form on SUPER+comma are QML in a
  single process, reading one palette out of `nix/data/palette.json`. That replaces
  a waybar bar, a dunst daemon, an eww window, a mostly-retired rofi and a Rust
  launcher wrapping a ten-patch fork of bemenu's C renderer, which between them
  had five theme paths and five ways of being told what colour to be.
  The same tree also owns idle: `qml/idle/` watches `ext-idle-notify-v1`,
  blanks the outputs after five minutes and asks logind to lock after ten,
  which `services.systemd-lock-handler` routes to `programs.hyprlock` through
  `lock.target`. So hyprlock and `services.gammastep` replace the old
  swaylock/redshift exec-once lines and the shell replaces swayidle. No X11
  session is left anywhere.
- **LibreWolf** (`nix/home/apps/librewolf.nix`). Runs natively through
  `programs.librewolf`, Home Manager's firefox-module wrapper, which owns
  `~/.librewolf`. The module writes the upstream arkenfox base plus personal
  overrides into `user.js`, stacked on top of the hardened defaults LibreWolf
  already ships.
- **haumea `~/Dokumente` skeleton** (`nix/home/base/dokumente.nix` and
  `nix/home/base/dokumente/`). The directory tree under `dokumente/` *is* the data.
  haumea loads it, and home-manager activation `mkdir -p`s every leaf into
  `~/Dokumente` on login, idempotently.
- **Wallpaper picker and rotation** (`nix/home/desktop/quickshell/qml/wallpaper/`). The
  shell itself: SUPER+W opens a thumbnail grid over `Wallpapers/`, and
  `Rotation.qml` picks a random file from the same tree on an hourly timer
  (and once at shell startup, so a fresh login is never blank). Either
  path runs `awww` directly, re-derives the accent from the applied image,
  and seeds a thin Papirus-Tint theme that re-points its folder icons at
  the matching prebuilt colour variant by symlink, no separate TUI or
  systemd timer involved.

## Testing

```bash
nix run .#nix-lint    # qmllint + QtTest over the shell, flake eval, cargo fmt/clippy/test
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
| `nix/data/settings.nix` | Install-time parameters (username, hostname, disk, swap) |
| `nix/system/disko.nix` | Single source of truth for the disk layout |
| `nix/system/hosts.nix` | facter-driven hardware config (NVIDIA via if-then-else on the report) |
| `nix/data/facter.json` | Committed stub (`{}`); the installer writes the real report on the target |
| `nix/modules/` | System configuration split by concern (boot, core, desktop, dots, form-factor, hardening, impermanence, limine-install, maintenance, network, searxng, steam, users, virtualisation) |
| `nix/home/` | home-manager profile (nixvim, Hyprland session, LibreWolf, Dokumente skeleton, wallpaper service) |
| `nix/system/iso.nix` | The LiveISO: embeds the flake at `/etc/dots`, auto-launches `dots-installer` on tty1 |
| `rust/installer-tui/` | The Rust/ratatui installer source |
| `nix/home/desktop/quickshell/` | The Quickshell config: bar, notifications, OSD, launcher, cheatsheet, settings |
| `Wallpapers/` | Five themed sets (light · storm · night · metis · misc) × three styles (abstract · minimal · os) |

[`nix/README.md`](nix/README.md) has the module-by-module design notes, including
what this repo's retired Gentoo installer used to do, kept around for history.

[`AI-DECLARATION.md`](AI-DECLARATION.md) records how much of this repo an agent
built, stage by stage.
