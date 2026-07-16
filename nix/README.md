# Nix target

This directory expresses the whole tokyonight-dots system as a Nix flake: NixOS +
home-manager + disko, plus a LiveISO carrying `installer-tui/` (a ratatui wizard
that replaces the afosi `.steps.yaml` flow). The repo's original Gentoo
installer has been fully retired — `install.sh` now only bootstraps
`dots-installer` via `nix run`; the Gentoo-era files, `.steps.yaml` and
`.konkrit.yaml` are gone from the tree (removed — git history preserves them).

## Quickstart

```bash
nix build .#iso                          # build the LiveISO (installer auto-starts on tty1)
dd if=result/iso/*.iso of=/dev/sdX bs=4M oflag=sync
# or, on an already-booted NixOS:
sudo nixos-rebuild switch --flake .#tokyonight-intel   # or #tokyonight-amd
```

## Gentoo → NixOS concept mapping

| Gentoo design element | NixOS replacement |
|---|---|
| erofs+dm-verity `/usr`, A/B triplets, seal/reseal, sysupdate, bless-boot | `/nix/store` + generations + `nixos-rebuild` — **not ported, dropped** |
| Portage-toolchain sysext (`emerge.raw`) | nothing needed — builds live in `/nix/store` |
| `portage-sync.timer` + reseal-on-suspend | `system.autoUpgrade` (`operation = "boot"`) + `nix.gc`/`nix.optimise` |
| `systemd-repart` GPT (ESP 2G, TPM2-LUKS2 btrfs root, random-key swap) | disko layout (`nix/disko.nix`), same shape |
| `Encrypt=tpm2` at repart time | installer runs `systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7` + `--recovery-key` post-format (adds a passphrase fallback the Gentoo design lacks) |
| ukify UKI + self-generated Secure Boot db keys | systemd-boot; `dots.secureboot.enable` (lanzaboote + sbctl) as post-install opt-in |
| `homectl` first-boot user | `users.users.<name>` + home-manager; username collected at install time by the TUI |
| afosi `.steps.yaml` wizard (removed — git history) | `installer-tui/` ratatui crate on the LiveISO |
| dotfiles → `/etc/skel` copy | home-manager `xdg.configFile.*.source` symlinks into the store |
| `make.conf.intel` / `make.conf.amd` | `nixosConfigurations.tokyonight-intel` / `tokyonight-amd` |
| konkrit 104-module firstboot catalog (`.konkrit.yaml`, removed — git history) | `nix/modules/hardening.nix`, declarative at build time |
| `COMMON_FLAGS` `-march=znver2`/`-march=skylake`, clang/LTO toolchain | **not ported** — custom `-march` forfeits the cache.nixos.org binary cache for near-zero gain; see `nix/hosts/*.nix` |
| `package.use` kernel `hardened` (hardened vanilla-kernel) | **not ported** — stock kernel + `nix/modules/hardening.nix` sysctl/params catalog instead |
| `package.use` gpg smartcard (`gnupg smartcard usb`, `gnutls pkcs11`) | `services.pcscd` + `hardware.gpgSmartcards` + `programs.gnupg.agent` (`nix/modules/core.nix`) |

## Layout

- `settings.nix` — install-time parameters (username, hostname, disk, swap). The
  TUI rewrites this file on the target; committed defaults keep evaluation green.
- `disko.nix` — single source of truth for the disk layout: consumed by the
  installer (`disko` CLI) *and* imported by the system config (generates
  `fileSystems`). Keep them from drifting by never duplicating the layout.
- `hosts/` — per-CPU-vendor deltas (microcode, GPU modules): `amd.nix`,
  `intel.nix`.
- `modules/` — system configuration split by concern: `boot.nix`, `core.nix`,
  `desktop.nix` (GNOME/GDM + Hyprland + pipewire), `flatpak.nix` (declarative
  Flathub packages), `hardening.nix`, `maintenance.nix`, `network.nix`,
  `secureboot.nix`, `users.nix`, `virtualisation.nix`.
- `home/` — home-manager profile. Dotfiles still under `files/` (fish,
  alacritty, gtk, neofetch, brave, BetterDiscord, claude) are reused wholesale
  via `xdg.configFile.*.source` (`default.nix`); Hyprland, waybar, dunst and
  rofi are full rewrites as native home-manager modules
  (`hyprland.nix`, `waybar.nix`, `dunst.nix`, `rofi/`), same for `nixvim.nix`,
  `librewolf.nix`, `claude.nix`, `random_wp.nix` (Wallhaven wallpaper timer)
  and `dokumente.nix`/`dokumente/` (haumea `~/Dokumente` skeleton).
- `iso.nix` — the LiveISO: embeds this flake at `/etc/dots`, auto-launches
  `dots-installer` on tty1.

## Machine-specific facts kept as-is

`nix/home/hyprland.nix` (monitor `eDP-1`, `services.gammastep` coordinates
`48.15`/`17.11`) — per-machine facts reused verbatim, not installer concerns.

## Secure Boot (post-install, optional)

The Gentoo flow generated db keys at install time; on NixOS this is an explicit
opt-in after the first boot:

```bash
sudo sbctl create-keys
# reboot into firmware, put Secure Boot into Setup Mode
sudo sbctl enroll-keys --microsoft
# set dots.secureboot.enable = true; in your host config, then:
sudo nixos-rebuild switch --flake ~/dots#tokyonight-intel
```
