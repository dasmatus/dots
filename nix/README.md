# Nix target

This directory expresses the whole tokyonight-dots system as a Nix flake: NixOS +
home-manager + disko, plus a LiveISO carrying `rust/installer-tui/` (a ratatui wizard
that replaces the afosi `.steps.yaml` flow). The repo's original Gentoo
installer has been fully retired — `install.sh` now only bootstraps
`dots-installer` via `nix run`; the Gentoo-era files, `.steps.yaml` and
`.konkrit.yaml` are gone from the tree (removed — git history preserves them).

## Quickstart

```bash
nix run .#iso                         # build + Secure Boot-sign the LiveISO
dd if=result-iso-signed/*.iso of=/dev/sdX bs=4M oflag=sync
# unsigned-only build (no signing keys touched): nix run .#iso-unsigned
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
| `Encrypt=tpm2` at repart time | installer runs `systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7` + `--recovery-key` post-format (adds a passphrase fallback the Gentoo design lacks) |
| ukify UKI + self-generated Secure Boot db keys | systemd-boot; `dots.secureboot.enable` (lanzaboote + sbctl) as post-install opt-in |
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
  `network.nix`, `secureboot.nix`, `users.nix`, `virtualisation.nix`.
  The former `flatpak.nix` (declarative Flathub packages) is gone — every
  GUI app is native now (see `home/pkgs.nix`).
- `home/` — home-manager profile, fully native modules (the raw `files/`
  dotfile tree is deleted — git history): `alacritty.nix`, `zellij.nix`,
  `fastfetch.nix` (ported from the old neofetch config), `fish.nix`,
  `hyprland.nix`, `waybar.nix`, `dunst.nix`, `rofi/`, `nixvim.nix`,
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

## Secure Boot

### Installed system (post-install, optional)

The Gentoo flow generated db keys at install time; on NixOS this is an explicit
opt-in after the first boot:

```bash
sudo sbctl create-keys
# reboot into firmware, put Secure Boot into Setup Mode
sudo sbctl enroll-keys --microsoft
# set dots.secureboot.enable = true; in your host config, then:
sudo nixos-rebuild switch --flake ~/Dokumente/gitlab/personal/dots#tokyonight
```

### Signed LiveISO (boot the installer with Secure Boot ON — the default)

`nix run .#iso` (and `nix run .#iso-full`) builds the ISO and rewrites its EFI chain
via `scripts/sign-iso.sh`: Fedora's Microsoft-signed shim becomes
`BOOTX64.EFI`, the ISO's GRUB gets an SBAT section and a signature from a
local MOK key (auto-generated once into gitignored `secrets/secureboot/`,
reused so enrolled machines keep booting re-signed ISOs), and every kernel
is signed too (GRUB verifies it through shim's protocol). Result:
`result-iso-signed/…-signed.iso` — that's the one to dd. The raw unsigned
nix output stays at `result-iso/iso/`; `nix run .#iso-unsigned` skips signing
entirely.

Two ways it boots with Secure Boot enforcing:

- **Factory machines** (Microsoft keys only): the first boot drops into
  MokManager (blue screen) → *Enroll key from disk* →
  `EFI/BOOT/tokyonight-dots-mok.cer` → reboot. One-time per machine.
- **Machines with your own keys**: if the db contains this cert alongside
  the Microsoft certs (the `sbctl enroll-keys --microsoft` shape — enroll
  `secrets/secureboot/MOK.cer` as an extra db key), shim validates GRUB
  straight from db: no prompts. `nix run .#nix-smoke` proves this chain in a
  NixOS test VM with enforcing Secure Boot firmware (it's the default).

#### Cosigning for zero prompts on your own machines

Nothing can be signed with Microsoft's private keys (only Microsoft holds
them; the shim we ship is already Microsoft-signed, which is what lets the
ISO boot at all). But `nix run .#iso-cosign` adds a **second** signature to GRUB
and the kernels using your local sbctl db key (`/var/lib/sbctl/keys/db`, the
same one lanzaboote signs installed systems with) on top of the MOK — the
PE files then carry both signatures. Any machine whose Secure Boot db
already trusts that key (i.e. where you ran `sbctl enroll-keys`) boots the
installer with **no MokManager prompt at all**; every other machine still
does the one-time MOK enrollment above. The private key is read via sudo in
place and never copied. `scripts/sign-iso.sh --extra-sign KEY CERT` cosigns
with an arbitrary key instead.
