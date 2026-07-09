"""Chroot phase, part 3: build offload, system packages, services, flatpak,
root account, hostname, dotfiles (→ /etc/skel), konkrit build + catalog."""

import glob
import os
import shutil

import common
import config
from common import info, step, warn, write_file

SYSTEM_PACKAGES = [
    "app-admin/sudo",
    "app-crypt/gnupg",
    "app-editors/neovim",
    "app-misc/neofetch",
    "app-shells/fish",
    "app-shells/starship",
    "dev-lang/sassc",
    "dev-python/neovim-remote",
    "dev-util/ccache",
    "dev-util/gitlab-cli",
    "media-fonts/nerdfonts",
    "media-fonts/noto-emoji",
    "net-misc/networkmanager",
    "net-wireless/iwd",
    "sys-apps/bat",
    "sys-apps/eza",
    "sys-apps/flatpak",
    "sys-fs/btrfs-progs",
    "www-client/brave-browser",
    "x11-apps/xinit",
    "x11-apps/xrandr",
    "x11-base/xorg-server",
    "x11-misc/autotiling",
    "x11-misc/picom",
    "x11-misc/polybar",
    "x11-misc/rofi",
    "x11-terms/alacritty",
    "x11-themes/papirus-icon-theme",
    "x11-wm/i3",
]

SUDOERS_WHEEL = """\
%wheel ALL=(ALL:ALL) ALL
"""

LOCAL_REPO_CONF = """\
[local]
location = /var/db/repos/local
masters = gentoo
auto-sync = no
"""

SKEL_CONFIG_DIRS = [
    "alacritty", "dunst", "fish", "hypr", "i3", "nvim", "polybar", "rofi",
    "neofetch", "gtk-2.0", "gtk-3.0", "zellij",
]


def configure():
    # ── Build offload (@builds subvol + zswap swap) ──────────────
    # Small/medium builds use the /var/tmp/portage tmpfs (fstab). Giants in
    # package.env build on the @builds btrfs subvol (nodatacow) mounted at
    # /var/tmp/notmpfs. zswap (kernel cmdline) fronts the encrypted swap, so
    # tmpfs overflow compresses in RAM before hitting disk.
    step("Build offload (@builds + zswap)")
    # /var/tmp/portage: tmpfs mountpoint. /var/tmp/notmpfs: the @builds subvol
    # — chown its root so Portage (uid/gid 250) can write there.
    common.run(["install", "-d", "-m", "0775", "-o", "portage", "-g", "portage",
                "/var/tmp/portage"])
    common.run(["chown", "portage:portage", "/var/tmp/notmpfs"])
    os.chmod("/var/tmp/notmpfs", 0o775)

    # ── System packages ──────────────────────────────────────────
    step("System packages")
    common.run(["emerge", "--quiet", "--noreplace"] + SYSTEM_PACKAGES)

    # Hyprland + extras (best-effort — may require hyprland overlay)
    if not common.run(["emerge", "--quiet", "--noreplace",
                       "gui-wm/hyprland", "gui-apps/waybar", "gui-apps/wofi"],
                      check=False):
        warn("hyprland emerge had issues — install missing packages after boot")
    if not common.run(["emerge", "--quiet", "--noreplace",
                       "gui-apps/hyprpaper", "gui-apps/hyprlock", "gui-apps/hypridle"],
                      check=False):
        warn("Some Hyprland extras unavailable — check the hyprland overlay after boot")

    # ── Services ─────────────────────────────────────────────────
    # systemctl enable works offline in a chroot (it only writes symlinks).
    # dbus + systemd-logind replace elogind and are enabled by systemd itself.
    step("systemd services")
    common.run(["systemctl", "enable", "NetworkManager.service"])
    common.run(["systemctl", "enable", "systemd-homed.service"])        # LUKS-backed homes
    common.run(["systemctl", "enable", "systemd-repart.service"])       # declarative partitioning
    common.run(["systemctl", "enable", "systemd-sysupdate.timer"])      # A/B update checks
    common.run(["systemctl", "enable", "systemd-boot-update.service"])  # keep sd-boot in sync
    common.run(["systemctl", "enable", "systemd-bless-boot.service"],   # A/B auto-rollback
               check=False, quiet=True)
    common.run(["systemctl", "enable", "bluetooth.service"], check=False, quiet=True)

    # ── Flatpak ──────────────────────────────────────────────────
    common.run(["flatpak", "remote-add", "--if-not-exists", "flathub",
                "https://dl.flathub.org/repo/flathub.flatpakrepo"],
               check=False, quiet=True)

    # ── Root account + sudo ──────────────────────────────────────
    # The primary user is NOT created here: homectl needs a running systemd +
    # a live D-Bus, which a chroot has neither of. It is provisioned on FIRST
    # BOOT (gentoo-firstboot.service); dotfiles are staged into /etc/skel so
    # systemd-homed copies them into the new encrypted home on homectl create.
    step("Root account")
    root_password = os.environ.get("root_password", "")
    if root_password:
        common.run(["chpasswd"], input_text=f"root:{root_password}\n")
        info("Root password set (from afosi answer)")
    else:
        info("Set root password:")
        common.run(["passwd", "root"])
    write_file("/etc/sudoers.d/wheel", SUDOERS_WHEEL, mode=0o440)

    # ── Hostname ─────────────────────────────────────────────────
    step("Hostname")
    hostname = os.environ.get("hostname") or "gentoo"
    write_file("/etc/hostname", f"{hostname}\n")
    write_file("/etc/hosts", (
        "127.0.0.1     localhost\n"
        "::1           localhost\n"
        f"127.0.1.1     {hostname}.localdomain  {hostname}\n"
    ))

    _dotfiles()
    _konkrit()


def _dotfiles():
    # Everything user-facing is written under /etc/skel; homed clones skel into
    # the new user's encrypted home on first boot and fixes ownership
    # automatically, so no chown here. Root-owned system files (portage, brave
    # policy) stay in /etc.
    step(f"Dotfiles from {config.DOTS_REPO}")
    dots_dir = "/etc/skel/dots"
    common.run(["git", "clone", config.DOTS_REPO, dots_dir])

    # Portage config — overwrite embedded version with repo copy
    info("Syncing portage config...")
    shutil.copy2(f"{dots_dir}/Gentoo configuration/make.conf.intel",
                 "/etc/portage/make.conf")
    for f in glob.glob(f"{dots_dir}/Gentoo configuration/package.use/*"):
        if os.path.isfile(f):
            shutil.copy2(f, f"/etc/portage/package.use/{os.path.basename(f)}")

    # Local overlay + custom profile (desktop/llvm/ccache)
    info("Installing local overlay and custom profile...")
    shutil.copytree(f"{dots_dir}/Gentoo configuration/local-repo",
                    "/var/db/repos/local", dirs_exist_ok=True)
    write_file("/etc/portage/repos.conf/local.conf", LOCAL_REPO_CONF)
    common.run(["eselect", "profile", "set",
                "local:default/linux/amd64/23.0/desktop/llvm/ccache"])

    # User config files → /etc/skel/.config/ (→ ~/.config on first boot)
    info("Syncing user configs into /etc/skel...")
    cfg_src = f"{dots_dir}/files"
    cfg_dst = "/etc/skel/.config"
    os.makedirs(cfg_dst, exist_ok=True)

    for d in SKEL_CONFIG_DIRS:
        if os.path.isdir(f"{cfg_src}/{d}"):
            shutil.copytree(f"{cfg_src}/{d}", f"{cfg_dst}/{d}", dirs_exist_ok=True)

    # picom lives under files/ directly (not a subdir)
    if os.path.isfile(f"{cfg_src}/picom.conf"):
        os.makedirs(f"{cfg_dst}/picom", exist_ok=True)
        shutil.copy2(f"{cfg_src}/picom.conf", f"{cfg_dst}/picom/picom.conf")

    # Claude Code config lives under ~/.claude/, not ~/.config/
    if os.path.isdir(f"{cfg_src}/claude"):
        claude_dst = "/etc/skel/.claude"
        os.makedirs(claude_dst, exist_ok=True)
        shutil.copy2(f"{cfg_src}/claude/settings.json", f"{claude_dst}/settings.json")
        if os.path.isfile(f"{cfg_src}/claude/settings.local.json"):
            shutil.copy2(f"{cfg_src}/claude/settings.local.json",
                         f"{claude_dst}/settings.local.json")
        info("Claude Code config staged to /etc/skel/.claude/")

    # Brave policy (system-wide, requires root)
    info("Applying Brave policy...")
    policy_src = f"{cfg_src}/brave/policies"
    if os.path.isdir(policy_src):
        os.makedirs("/etc/brave/policies", exist_ok=True)
        shutil.copytree(f"{policy_src}/managed", "/etc/brave/policies/managed",
                        dirs_exist_ok=True)
        if os.path.isdir(f"{policy_src}/recommended"):
            shutil.copytree(f"{policy_src}/recommended",
                            "/etc/brave/policies/recommended", dirs_exist_ok=True)
        common.run(["chmod", "-R", "755", "/etc/brave"])
        for j in glob.glob("/etc/brave/policies/managed/*.json"):
            os.chmod(j, 0o644)
        info("Brave policy installed to /etc/brave/policies/")
    else:
        warn("Brave policy directory not found in dots repo — skipping")


def _konkrit():
    # ── konkrit: hardening + Alpine Flatpak VM (agent-first tooling) ──
    # Built here (installed system), RUN on first boot (after the user exists)
    # by gentoo-firstboot.sh. NOTE: konkrit's catalog is Arch-targeted — a step
    # that calls an absent program (pacman, mkinitcpio) makes konkrit abort its
    # whole run on Gentoo, so the first-boot call is guarded and the catalog
    # (shipped as <dots>/.konkrit.yaml) is meant to be reviewed for this host.
    step("konkrit (build + Flatpak-VM prerequisites)")
    # GURU community overlay — provides dev-libs/hardened_malloc (and other
    # packages konkrit's catalog pulls that aren't in ::gentoo). Enable it so
    # the first-boot `emerge dev-libs/hardened_malloc` resolves.
    common.run(["eselect", "repository", "enable", "guru"], check=False, quiet=True)
    common.run(["emaint", "sync", "-r", "guru", "-q"], check=False, quiet=True)
    if not common.run(["emerge", "--quiet", "--noreplace", "dev-lang/rust"],
                      check=False):
        warn("rust emerge failed — konkrit will not build")
    # Full-catalog choice pulls the Alpine/QEMU Flatpak-VM stack:
    if not common.run(["emerge", "--quiet", "--noreplace",
                       "app-emulation/libvirt",
                       "app-emulation/qemu",
                       "app-emulation/virt-manager",
                       "sys-firmware/edk2-ovmf"], check=False):
        warn("libvirt/qemu stack incomplete — the konkrit VM may not come up")
    common.run(["systemctl", "enable", "libvirtd.socket"], check=False, quiet=True)

    if shutil.which("cargo"):
        info("Building konkrit (cargo, release)…")
        if not common.run(["cargo", "install", "--quiet", "--git",
                           config.KONKRIT_REPO, "--root", "/usr/local"],
                          check=False):
            warn("konkrit build failed — first-boot hardening will be skipped")
    os.makedirs("/etc/konkrit", exist_ok=True)
    if os.path.isfile("/etc/skel/dots/.konkrit.yaml"):
        shutil.copy2("/etc/skel/dots/.konkrit.yaml", "/etc/konkrit/konkrit.yaml")
        info("konkrit catalog installed to /etc/konkrit/konkrit.yaml")
    else:
        warn(".konkrit.yaml not found in dots repo — first-boot hardening will be skipped")
