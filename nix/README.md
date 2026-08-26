# Nix target

This directory expresses the whole tokyonight-dots system as a Nix flake: NixOS +
home-manager + disko, plus a LiveISO carrying `rust/installer-tui/` (a ratatui wizard
that replaces the afosi `.steps.yaml` flow). The repo's original Gentoo
installer has been fully retired — `install.sh` now only bootstraps
`dots-installer` via `nix run`; the Gentoo-era files, `.steps.yaml` and
`.konkrit.yaml` are gone from the tree (removed — git history preserves them).

## Quickstart

```bash
nix run .#iso                         # build the LiveISO (plain, unsigned)
dd if=result-iso/iso/*.iso of=/dev/sdX bs=4M oflag=sync
# or, on an already-booted NixOS:
sudo nixos-rebuild switch --flake .#tokyonight
```

## Gentoo → NixOS concept mapping

| Gentoo design element | NixOS replacement |
|---|---|
| erofs+dm-verity `/usr`, A/B triplets, seal/reseal, sysupdate, bless-boot | `/nix/store` + generations + `nixos-rebuild` — **not ported, dropped** |
| Portage-toolchain sysext (`emerge.raw`) | nothing needed — builds live in `/nix/store` |
| `portage-sync.timer` + reseal-on-suspend | `system.autoUpgrade` (`operation = "boot"`) + `nix.gc`/`nix.optimise` |
| `systemd-repart` GPT (ESP 2G, TPM2-LUKS2 btrfs root, random-key swap) | disko layout (`nix/disko.nix`), same shape |
| `Encrypt=tpm2` at repart time | installer runs `systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7` + `--recovery-key` post-format, with a random keyfile (not a login password) as the format-time passphrase |
| ukify UKI + self-generated Secure Boot db keys | Limine, no Secure Boot / UKI signing — TPM2 auto-unlock + LUKS recovery key only (systemd-boot replaced: it aborted nixos-install on the empty `/etc/machine-id` that impermanence produces) |
| `homectl` first-boot user | `users.users.<name>` + home-manager; username collected at install time by the TUI |
| afosi `.steps.yaml` wizard (removed — git history) | `rust/installer-tui/` ratatui crate on the LiveISO |
| dotfiles → `/etc/skel` copy | home-manager native modules (`programs.*`); `files/` fully ported and deleted — git history |
| `make.conf.intel` / `make.conf.amd` | single `nixosConfigurations.tokyonight` + a nixos-facter report (`nix/hosts.nix`) |
| konkrit 104-module firstboot catalog (`.konkrit.yaml`, removed — git history) | `nix/modules/hardening.nix`, declarative at build time |
| `COMMON_FLAGS` `-march=znver2`/`-march=skylake`, clang/LTO toolchain | **not ported** — custom `-march` forfeits the cache.nixos.org binary cache for near-zero gain |
| `package.use` kernel `hardened` (hardened vanilla-kernel) | **not ported** — stock kernel + `nix/modules/hardening.nix` sysctl/params catalog instead |
| `package.use` gpg smartcard (`gnupg smartcard usb`, `gnutls pkcs11`) | `services.pcscd` + `hardware.gpgSmartcards` + `programs.gnupg.agent` (`nix/modules/core.nix`) |

## Layout

- `settings.nix` — install-time parameters (username, hostname, disk, swap). The
  TUI rewrites this file on the target; committed defaults keep evaluation green.
- `disko.nix` — single source of truth for the disk layout: consumed by the
  installer (`disko` CLI) *and* imported by the system config (generates
  `fileSystems`). Keep them from drifting by never duplicating the layout.
- `hosts.nix` — hardware config driven by the nixos-facter report
  (`facter.json`): microcode, firmware, GPU modules and amd_pstate come from
  detection; NVIDIA is switched via if-then-else on the report (facter
  deliberately doesn't auto-configure the proprietary driver).
- `facter.json` — committed stub (`{}`) that keeps evaluation green with all
  detection off; the installer overwrites it on the target.
- `modules/` — system configuration split by concern: `boot.nix`, `core.nix`,
  `desktop.nix` (GNOME/GDM + Hyprland + pipewire; GNOME core apps via
  `services.gnome.core-apps`), `hardening.nix`, `maintenance.nix`,
  `network.nix`, `users.nix`, `virtualisation.nix`.
  The former `flatpak.nix` (declarative Flathub packages) is gone — every
  GUI app is native now (see `home/pkgs.nix`). The former `secureboot.nix`
  (lanzaboote + sbctl UKI signing) is gone — Secure Boot was removed in
  favor of plain systemd-boot + TPM2 auto-unlock.
- `home/` — home-manager profile, fully native modules (the raw `files/`
  dotfile tree is deleted — git history): `alacritty.nix`, `zellij.nix`,
  `fastfetch.nix` (ported from the old neofetch config), `fish.nix`,
  `hyprland.nix`, `quickshell/` (the desktop shell: bar, notification daemon,
  media-key OSD, launcher, keybind cheatsheet and settings form, all QML in
  one process — this is where waybar, dunst, eww, rofi and the beamenu
  launcher went), `nixvim.nix`,
  `librewolf.nix`, `claude.nix` (Claude Code + nix-built `ccbar` statusline),
  `pkgs.nix` (ex-flatpak GUI apps incl. the Haveno AppImage wrap and the
  Newelle→Claude Code wiring), `git.nix`, `random_wp.nix` (Wallhaven
  wallpaper timer), `dots-repo.nix` (first-login clone of this repo +
  install-answer restore) and `dokumente.nix`/`dokumente/` (haumea
  `~/Dokumente` skeleton).
- `iso.nix` — the LiveISO: embeds this flake at `/etc/dots`, auto-launches
  `dots-installer` on tty1. The installer stages a writable copy of that
  flake at `/tmp/dots-flake` and runs `nixos-install` from there; the
  installed system no longer gets an `/etc/dots` copy — instead a
  first-login clone lands at `~/Dokumente/gitlab/personal/dots` (see
  `dots-repo.nix` above).

## Hardware detection (nixos-facter)

Fresh installs need nothing: the TUI runs `nixos-facter` on the target and
writes the report into the staged flake (`/tmp/dots-flake`) before
`nixos-install`, then stashes it at `/var/lib/dots/facter.json` on the
target. At first login, the `dots-clone` home-manager user service clones
this repo to `~/Dokumente/gitlab/personal/dots` and restores the stashed
report (and `settings.nix`) into it. To adopt this on an already-installed
machine (or after swapping hardware):

```bash
cd ~/Dokumente/gitlab/personal/dots   # or wherever the clone lives
sudo nix run nixpkgs#nixos-facter -- -o nix/facter.json   # overwrite the stub
sudo nixos-rebuild switch --flake .#tokyonight
```

Keep the real report as local dirty state — **never commit it** (it embeds
serial numbers and MAC addresses, and each machine's report differs). This
works because the stub is a *tracked* file: git-repo flakes include dirty
tracked modifications but ignore untracked files. The report lands as a
dirty tracked modification in the `~/Dokumente/gitlab/personal/dots` clone,
so `system.autoUpgrade` (which builds from that clone) always sees the real
report.

## Machine-specific facts kept as-is

`nix/home/hyprland.nix` (monitor `eDP-1`, `services.gammastep` coordinates
`48.15`/`17.11`) — per-machine facts reused verbatim, not installer concerns.

## Disk encryption (no Secure Boot)

Secure Boot / UKI signing was removed — neither the installed system nor the
LiveISO is signed, and `lanzaboote`, `sbctl`, the Microsoft-signed shim and
`scripts/sign-iso.sh` are all gone. Boot is plain **Limine** off the ESP.

Limine replaces systemd-boot because `systemd-boot-builder.py` reads
`/etc/machine-id` and aborts `nixos-install` when it is empty — exactly the
state this system's impermanence setup produces at install time (tmpfs `/`
wiped each boot, and `/etc/machine-id` intentionally not persisted — it
regenerates each boot regardless of `system.etc.overlay.mutable`).
`limine-install.py` has no machine-id
dependency. Limine installs to the firmware's removable `\EFI\BOOT\BOOTX64.EFI`
path (`boot.loader.efi.canTouchEfiVariables = false`), so it never runs
`efibootmgr` and is immune to the efibootmgr NVRAM-write failure
(nixpkgs #493017). `limine-install.py` also calls `nix-env --list-generations`
unconditionally, which can abort `nixos-install` when the target profile
is not ready in the chroot; `nix/modules/limine-install.nix` wraps the upstream
installer and bootstraps a single-generation profile before delegating to it.

PCR 7 (the TPM2 unlock binding) is firmware-measured Secure Boot policy, not
bootloader-dependent — neither systemd-boot nor Limine writes PCR 7, and
Secure Boot is off on both the LiveISO and the installed system, so the
unseal value is identical between enrollment and first boot via Limine.

The LUKS root (`/dev/tokyonightvg/root`, see `disko.nix`) unlocks two ways:

- **TPM2 auto-unlock** — the installer enrolls a TPM2 token on PCR 7
  (`systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7`), so a normal boot
  unlocks the root with no prompt.
- **Recovery key** — the installer also enrolls a recovery key, printed on the
  installer's Done screen and saved to `/root/luks-recovery.txt` on the target.
  That is the only offline fallback — write it down.

The format-time LUKS passphrase is a one-shot random keyfile (64 bytes from
`/dev/urandom`), not a login password: it authorizes the TPM2/recovery
enrollment and is then shredded, so the disk is decoupled from the user/root
passwords. The root account is left locked (no password) — `nixos-install
--no-root-passwd` keeps it that way, and the only login is the wheel user via
sudo.
