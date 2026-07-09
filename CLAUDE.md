# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Gentoo Linux dotfiles repository ("tokyonight-dots") containing:
- **`files/`** — user configs copied to `~/.config/` (alacritty, dunst, fish, hypr, i3, nvim, polybar, rofi, neofetch, gtk-2.0, gtk-3.0, picom.conf)
- **`Gentoo configuration/`** — Portage configs (`make.conf.amd`, `make.conf.intel`, `package.use/`, `local-repo/`)
- **`install.sh` + `installer/`** — A fully automated **full-systemd, immutable-`/usr`** Gentoo installer, modeled on Poettering's [*Fitting Everything Together*](https://0pointer.net/blog/fitting-everything-together.html). `install.sh` is only a **thin curl wrapper**: it runs the Python package `installer/` in place (repo checkout / VM 9p share) or fetches it to `/root/installer/` (`curl | bash`), then execs `python3 installer/main.py` with `PYTHONUNBUFFERED=1`. The package (stdlib-only, flat imports) is split by phase: `bootstrap.py` (afosi first pass) → host phase (`preflight.py`, `partition.py`, `stage3.py`, `hostconfig.py`) → chroot phase (`chroot_base.py`, `chroot_boot.py`, `chroot_system.py`, `chroot_sysupdate.py`, `seal.py`), orchestrated by `main.py` with shared helpers in `common.py`/`config.py`. The chroot phase is the same package run via `chroot … python3 /root/installer/main.py --phase chroot` (values travel as env vars); runtime system scripts (`rebuild-uki`, `sysext-update`, firstboot, …) remain bash, embedded as string constants. `systemd-repart` declaratively creates GPT (Discoverable Partitions Spec) partitions: ESP, a **TPM2-encrypted btrfs root** (`Encrypt=tpm2`, LUKS2, no passphrase — holds mutable `/etc`+`/var`+`/home` as subvols `@root`/`@home`/`@snapshots`/`@builds`), a `linux-generic` random-key encrypted swap, and A/B **`usr`/`usr-verity`/`usr-verity-sig`** triplets. `/usr` is sealed into a **read-only erofs + dm-verity image** (roothash signed, `usrhash=` baked into the UKI). The **Portage toolchain ships as a `systemd-sysext`** (`/var/lib/extensions/emerge.raw`) so the base `/usr` stays lean; **updates reseal** (`sysext merge` → `emerge --root=staging` → seal → `systemd-sysupdate` A/B) via `/usr/lib/gentoo/sysext-update` + `gentoo-reseal.service`. systemd-boot + UKI (built with `ukify`), systemd init, `systemd-homed` first-boot user, i3 + Hyprland. **No LVM, no dm-integrity, no interactive passphrase.** Stage3 comes from the **tux.rainside.sk** mirror (`hardened-selinux-systemd` profile; pointer file derived from the profile name). Requires a **systemd (≥254)** live env with a **TPM2** (or emulated swtpm) + `cargo` + `python3`. TPM2 binds PCR 7 (SecureBoot state) in production; a recovery key is enrolled. Env knobs: `TPM2_PCRS` (empty = no PCR policy, used by the VM tests), `USR_SIZE`, `STAGE3_BASE` (mirror override), `INSTALL_STOP_AFTER` (test checkpoint).
- **`.steps.yaml`** — afosi (`agent-first-os-installer`) config: the install-time user prompts (disk, hostname, root password, wipe confirm). `installer/bootstrap.py` builds the `installer` binary and hands off to it; its final action re-enters `bash /root/install.sh` with answers in the env (`AFOSI_DRIVEN=1`).
- **`.konkrit.yaml`** — konkrit hardening catalog (100+ modules) + Alpine/QEMU Flatpak VM, run on **first boot**. Generated via `konkrit catalog`, then **adapted Arch→Gentoo** (pacman→emerge, mkinitcpio/sbctl/grub→`rebuild-uki`, `/etc/cmdline.d`→`/etc/kernel/cmdline.d`, hardened_malloc→`dev-libs/hardened_malloc` from GURU, apparmor.d→`sec-policy/apparmor-profiles`, linux-hardened disabled). `{{user}}` is set by the first-boot service. See the adaptation banner atop the file; keep it accurate if you re-generate.
- **`Wallpapers/`** — Themed wallpaper sets (light/storm/night/metis/misc × abstract/minimal/os)
- **`user.js`** — Firefox user.js hardening preferences

## Agent-first tooling (afosi + konkrit)

Two Rust crates from the `agents-make-an-os` family are built from source (`cargo`) during install:
- **afosi** builds in the **live env**; its `.steps.yaml` is validated by regenerating structure with `installer emit-cfg` and editing only values. Forms are `!Input`/`!YesNo`/`!Choice`; all answers are exported as env vars to the final `!action` that runs `bash /root/install.sh`.
- **konkrit** builds in the **installed system** (chroot), runs on first boot. Both tools **dry-run in debug builds, execute in release** — `cargo install` produces release binaries. konkrit **aborts its whole run if a step's program is missing** (e.g. `pacman` on Gentoo), so the first-boot call is guarded with `|| warn` and never blocks boot.

## Deployment

The installer is designed to run from a Gentoo live environment:
```bash
curl -fsSL https://gitlab.com/TenTypekMatus/tokyonight-dots/-/raw/main/install.sh | bash
```

After installation, dotfiles are cloned to `~/dots` and synced automatically by the installer. For manual dotfile sync, the installer copies:
- `files/<dir>` → `~/.config/<dir>` for each of: alacritty, dunst, fish, hypr, i3, nvim, polybar, rofi, neofetch, gtk-2.0, gtk-3.0
- `files/picom.conf` → `~/.config/picom/picom.conf`
- `Gentoo configuration/make.conf.intel` (or `.amd`) → `/etc/portage/make.conf`
- `Gentoo configuration/package.use/*` → `/etc/portage/package.use/`
- `files/brave/policies/` → `/etc/brave/policies/` (system-wide)
- `Gentoo configuration/local-repo/` → `/var/db/repos/local/` + `repos.conf/local.conf` + profile set to `local:default/linux/amd64/23.0/desktop/llvm/ccache`

## Architecture decisions

- **Two make.conf variants**: `make.conf.intel` (skylake `-march`, `VIDEO_CARDS="intel i915"`) and `make.conf.amd` — keep them in sync when changing shared USE flags
- **Neovim config** uses lazy.nvim with modules split under `lua/nvimcfg/`: `plugins.lua` registers all plugins; `language/`, `appearance/`, `editor/` subdirs configure them. Leader key is `\`
- **Fish** auto-starts X on tty1 login (`startx`), uses starship prompt, aliases `cat`→`bat` and `ls`→`eza`
- **`.gitignore`** explicitly ignores `files/brave/` (contains personal browser profile data) and `.codegraph/`

## Automatic maintenance (installed system)

The installer provisions background maintenance via systemd units (all at `Nice=19`/idle IO):
- **Binary packages**: `FEATURES="getbinpkg binpkg-request-signature"` + `/etc/portage/binrepos.conf/gentoobinhost.conf` (official Gentoo binhost) so emerges install prebuilt binaries where USE/ABI match, else build from source.
- **Storage (no LVM, no dm-integrity)**: `systemd-repart` GPT + DPS. The TPM2-encrypted btrfs **root** holds `/etc`+`/var`+`/home` (btrfs data-checksums replace dm-integrity — as the article recommends). `/usr` is the **read-only dm-verity image**. Build scratch = the `@builds` subvol at `/var/tmp/notmpfs` (`nodatacow`); small builds use the `/var/tmp/portage` **tmpfs** (`size=60%`). Swap is `linux-generic` + a crypttab random key, fronted by **zswap** (kernel cmdline `zswap.*`).
- **Updates are RESEAL, not in-place emerge** (the running `/usr` is read-only). `/usr/lib/gentoo/portage-check-updates` (via `portage-sync.timer`, 6 h) flags `/var/lib/portage/.updates-pending`; on **suspend (`pre`)** `60-portage-reseal` starts `gentoo-reseal.service` → `/usr/lib/gentoo/sysext-update`: `systemd-sysext merge` (toolchain) → `emerge --root=<staging> -uDN @world` → seal a new erofs+dm-verity `/usr` + `ukify` a new UKI (new `usrhash=`) → `systemd-sysupdate update` writes the inactive A/B slot → reboot into it (`systemd-bless-boot` auto-reverts a bad boot). **To change packages you reseal**, not `emerge` on the live host.
- **`rebuild-uki`** (`/usr/lib/gentoo/rebuild-uki`): re-bakes the UKI with `ukify` from `/etc/kernel/cmdline{,.d}`, **preserving the active `usrhash=`** (read from `/proc/cmdline`) and signing with `/etc/kernel/keys/db.*`. konkrit's kernel/boot-param modules call it.
- **Keys**: the verity roothash signing key + Secure-Boot db key are generated at install and kept on the mutable root at `/etc/kernel/keys/` (root-only) so reseals can re-sign; never sealed into `/usr`.

## VM tests (`tests/`, `Justfile`)

The installer is validated in throwaway libvirt VMs — see `tests/README.md`. `just lint` (static, no VM), `just smoke` (OVMF + emulated-swtpm TPM2 VM boots SystemRescue via a remastered ISO, runs the local `install.sh` to the `INSTALL_STOP_AFTER=stage3` checkpoint over a 9p share, asserts the repart/TPM2/DPS layout), `just e2e` (full install + reboot + read-only dm-verity `/usr` boot oracle). Runs under `qemu:///session` (no root). `just setup` installs prereqs (swtpm, xorriso, shellcheck). All generated artifacts live in the gitignored `tests/artifacts/`.

## Theme

All configs use the **Tokyonight** colorscheme. When adding or modifying config files, maintain Tokyonight color consistency across components.
