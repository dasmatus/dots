#!/usr/bin/env bash
# ================================================================
#  Gentoo automated FDE installer
#
#  Partitioning     : systemd-repart (declarative) → GPT | 2 GiB ESP | LUKS2
#  Root crypto      : LUKS2 + dm-integrity (hmac-sha256, authenticated) → btrfs
#  btrfs subvolumes : @root  @home  @snapshots
#  Bootloader       : systemd-boot + Unified Kernel Images (UKI)
#  Init system      : systemd
#  Extras           : systemd-repart · systemd-sysupdate (A/B UKI) · systemd-homed
#  Window managers  : i3  +  Hyprland
#  Dotfiles         : https://gitlab.com/TenTypekMatus/tokyonight-dots
#
#  Usage:
#    curl -fsSL https://gitlab.com/TenTypekMatus/tokyonight-dots/-/raw/main/install.sh | bash
#
#  Requirements: a SYSTEMD-based live env (SystemRescue / Gentoo LiveGUI /
#    Arch ISO — NOT the OpenRC admin CD) with: systemd-repart, cryptsetup,
#    bootctl, mkfs.btrfs, btrfs, curl
# ================================================================
set -euo pipefail

# ── Constants ────────────────────────────────────────────────────
readonly DOTS_REPO="https://gitlab.com/TenTypekMatus/tokyonight-dots"
readonly DOTS_RAW="https://gitlab.com/TenTypekMatus/tokyonight-dots/-/raw/main"
readonly AFOSI_REPO="https://gitlab.com/agents-make-an-os/tooling/agent-first-os-installer.git"
readonly KONKRIT_REPO="https://gitlab.com/agents-make-an-os/tooling/konkrit.git"
readonly STAGE3_BASE="https://distfiles.gentoo.org/releases/amd64/autobuilds"
readonly STAGE3_PROFILE="current-stage3-amd64-systemd"
readonly MOUNT="/mnt"
readonly BTRFS_OPTS="noatime,compress=zstd:1,space_cache=v2"
readonly ESP_SIZE="2G"   # holds systemd-boot + A/B UKIs (sysupdate InstancesMax=2)

# ── Colours + helpers ────────────────────────────────────────────
RED='\033[0;31m' GRN='\033[0;32m' YLW='\033[0;33m'
CYN='\033[0;36m' BLD='\033[1m'    RST='\033[0m'
info() { printf "${GRN}[+]${RST} %s\n"           "$*"; }
step() { printf "\n${CYN}${BLD}━━ %s ${RST}\n"   "$*"; }
warn() { printf "${YLW}[!]${RST} %s\n"           "$*"; }
die()  { printf "${RED}[✗]${RST} %s\n" "$*" >&2; exit 1; }
ask()  { printf "${BLD}[?]${RST} %s "             "$*"; }

# ── afosi prompt front-end (first pass only) ─────────────────────
# The user-facing entry point stays `curl … | bash`. On the first pass we build
# the afosi `installer`, let it collect the install answers via its TUI, then it
# re-enters THIS script with every answer exported as an env var + AFOSI_DRIVEN=1.
# The second pass (below) skips this block and runs the real install headless.
if [[ "${AFOSI_DRIVEN:-0}" != "1" ]]; then
  [[ $EUID -eq 0 ]] || die "Must run as root"
  step "Bootstrapping the afosi prompt front-end"
  command -v git   &>/dev/null || die "git required in the live env"
  command -v cargo &>/dev/null || die "Rust/cargo required in the live env to build afosi \
(e.g. 'pacman -Sy rust' on an Arch/SystemRescue ISO)"

  if ! command -v installer &>/dev/null; then
    info "Building afosi installer (cargo, release)…"
    cargo install --quiet --git "${AFOSI_REPO}" --root /usr/local \
      || die "afosi build failed"
  fi

  # afosi's action re-runs this exact script; fetch a stable on-disk copy of both.
  info "Fetching install.sh + .steps.yaml…"
  curl -fsSL "${DOTS_RAW}/install.sh"  -o /root/install.sh
  curl -fsSL "${DOTS_RAW}/.steps.yaml" -o /root/.steps.yaml

  # Hand off: afosi asks the questions on the TTY, then its final Action runs
  # `bash /root/install.sh` with the answers (disk, hostname, root_password,
  # wipe_confirm) in the environment.
  exec installer /root/.steps.yaml < /dev/tty
fi

# ═════════════════════════════════════════════════════════════════
# Second pass (AFOSI_DRIVEN=1): install answers arrive as env vars
#   $disk  $wipe_confirm  $hostname  $root_password
# ═════════════════════════════════════════════════════════════════

# ── Pre-flight ───────────────────────────────────────────────────
step "Pre-flight checks"

[[ $EUID -eq 0 ]]          || die "Must run as root"
[[ -d /sys/firmware/efi ]] || die "UEFI not detected — EFI boot required"

# systemd-repart + bootctl are only present on a systemd live env. Their
# absence means the OpenRC admin CD was booted — bail early with guidance.
for cmd in systemd-repart bootctl cryptsetup mkfs.btrfs btrfs sgdisk curl; do
  command -v "${cmd}" &>/dev/null \
    || die "Missing: ${cmd}  (boot a systemd live ISO: SystemRescue / Gentoo LiveGUI / Arch)"
done

# dm-integrity needs the integritysetup helper + kernel module at open time
command -v integritysetup &>/dev/null \
  || warn "integritysetup not found — dm-integrity may fail (install cryptsetup-integrity)"

# ── Disk selection (from afosi answers) ──────────────────────────
step "Disk selection"

DISK="${disk:?disk answer missing — run via 'installer .steps.yaml'}"
[[ -b "${DISK}" ]] || die "Target disk '${DISK}' is not a block device"
# afosi asked the YesNo confirmation; require the affirmative here too.
[[ "${wipe_confirm:-}" == "true" ]] \
  || die "Wipe of ${DISK} not confirmed — aborting"
if lsblk -no MOUNTPOINTS "${DISK}" 2>/dev/null | grep -qE '^/'; then
  die "${DISK} has a mounted partition — refusing to erase"
fi
info "Target disk: ${DISK}"
warn "ALL DATA ON ${DISK} WILL BE PERMANENTLY ERASED."

# NVMe / eMMC partition suffix is 'p', SATA/SAS use plain numbers
if [[ "${DISK}" =~ nvme|mmcblk ]]; then
  PART_EFI="${DISK}p1"
  PART_LUKS="${DISK}p2"
else
  PART_EFI="${DISK}1"
  PART_LUKS="${DISK}2"
fi

# ── Partitioning (declarative, systemd-repart) ───────────────────
step "Partitioning ${DISK} (systemd-repart)"
sgdisk --zap-all "${DISK}" &>/dev/null   # clear stale GPT/LUKS headers first

# repart.d drop-ins are the single source of truth for the on-disk layout.
# The SAME definitions are shipped into the installed system (see chroot body)
# so systemd-repart.service stays idempotent on first boot.
REPART_DEFS=$(mktemp -d)
cat > "${REPART_DEFS}/10-esp.conf" <<EOF
[Partition]
Type=esp
Format=vfat
SizeMinBytes=${ESP_SIZE}
SizeMaxBytes=${ESP_SIZE}
Label=ESP
EOF
# Partition 2 backs LUKS2+dm-integrity+btrfs, all set up manually below — so
# repart only lays down the partition slot (no Format=, no Encrypt=). Explicit
# "Linux LUKS" GPT type (CA7D7CCB…) keeps lsblk/blkid honest.
cat > "${REPART_DEFS}/20-cryptroot.conf" <<EOF
[Partition]
Type=CA7D7CCB-63ED-4C53-861C-1742536059CC
Label=cryptroot
EOF

systemd-repart \
  --dry-run=no \
  --empty=force \
  --definitions="${REPART_DEFS}" \
  "${DISK}"
rm -rf "${REPART_DEFS}"

partprobe "${DISK}"
udevadm settle
info "GPT created: ${PART_EFI} (${ESP_SIZE} ESP)  ${PART_LUKS} (LUKS+integrity)"

# ── LUKS2 + dm-integrity ─────────────────────────────────────────
step "LUKS2 + dm-integrity setup"
info "Formatting ${PART_LUKS} — you'll enter the passphrase twice."
warn "dm-integrity initialises integrity tags across the WHOLE partition —"
warn "this does a full-device wipe pass and can take a long while. Be patient."
# --integrity hmac-sha256 layers dm-integrity beneath dm-crypt → authenticated
# encryption (detects tampering, not just bit-rot). 4K sectors are required for
# the integrity journal and match modern SSDs.
cryptsetup luksFormat \
  --type        luks2           \
  --cipher      aes-xts-plain64 \
  --key-size    512             \
  --hash        sha512          \
  --pbkdf       argon2id        \
  --iter-time   4000            \
  --integrity   hmac-sha256     \
  --sector-size 4096            \
  "${PART_LUKS}"

info "Opening LUKS container as 'cryptroot'..."
cryptsetup open "${PART_LUKS}" cryptroot

LUKS_UUID=$(cryptsetup luksUUID "${PART_LUKS}")
info "LUKS UUID: ${LUKS_UUID}"

# ── btrfs filesystem ─────────────────────────────────────────────
step "btrfs + subvolumes"
# ESP was already formatted vfat by systemd-repart above.
mkfs.btrfs -f -L gentoo /dev/mapper/cryptroot

BTRFS_UUID=$(blkid -s UUID -o value /dev/mapper/cryptroot)
info "btrfs UUID: ${BTRFS_UUID}"

info "Creating subvolumes: @root  @home  @snapshots"
mount /dev/mapper/cryptroot "${MOUNT}"
btrfs subvolume create "${MOUNT}/@root"
btrfs subvolume create "${MOUNT}/@home"
btrfs subvolume create "${MOUNT}/@snapshots"
umount "${MOUNT}"

info "Mounting subvolumes..."
mount -o "${BTRFS_OPTS},subvol=@root"       /dev/mapper/cryptroot "${MOUNT}"
mkdir -p "${MOUNT}"/{home,.snapshots,boot}
mount -o "${BTRFS_OPTS},subvol=@home"       /dev/mapper/cryptroot "${MOUNT}/home"
mount -o "${BTRFS_OPTS},subvol=@snapshots"  /dev/mapper/cryptroot "${MOUNT}/.snapshots"
mount "${PART_EFI}" "${MOUNT}/boot"   # EFI partition doubles as /boot

# ── Stage3 ───────────────────────────────────────────────────────
step "Stage3 download"
_latest=$(curl -fsSL "${STAGE3_BASE}/${STAGE3_PROFILE}/latest-stage3-amd64-systemd.txt")
_s3file=$(grep -v '^#' <<< "${_latest}" | awk 'NF{print $1}' | head -1)
STAGE3_URL="${STAGE3_BASE}/${STAGE3_PROFILE}/${_s3file}"

info "Fetching: ${STAGE3_URL}"
curl -fsSL "${STAGE3_URL}"     -o "${MOUNT}/stage3.tar.xz"
curl -fsSL "${STAGE3_URL}.asc" -o "${MOUNT}/stage3.tar.xz.asc" 2>/dev/null || true

if command -v gpg &>/dev/null && [[ -f "${MOUNT}/stage3.tar.xz.asc" ]]; then
  gpg --keyserver hkps://keys.openpgp.org \
      --recv-keys 13EBBDBEDE7A12775DFDB1BABB572E0E2D182910 2>/dev/null || true
  if gpg --verify "${MOUNT}/stage3.tar.xz.asc" "${MOUNT}/stage3.tar.xz" 2>/dev/null; then
    info "GPG signature OK"
  else
    warn "GPG verify failed — continuing (check manually if concerned)"
  fi
fi

info "Extracting..."
tar xpf "${MOUNT}/stage3.tar.xz" --xattrs-include='*.*' --numeric-owner -C "${MOUNT}"
rm -f "${MOUNT}/stage3.tar.xz" "${MOUNT}/stage3.tar.xz.asc"
cp /etc/resolv.conf "${MOUNT}/etc/resolv.conf"

# ── Portage config (pre-chroot) ──────────────────────────────────
step "Portage configuration"
mkdir -p "${MOUNT}/etc/portage/package.use"

# make.conf — matches dots repo make.conf.intel; dots repo overwrites at end of chroot
cat > "${MOUNT}/etc/portage/make.conf" <<'MAKECONF'
COMMON_FLAGS="-O2 -march=skylake -pipe"
CFLAGS="${COMMON_FLAGS}"
CXXFLAGS="${COMMON_FLAGS}"
FCFLAGS="${COMMON_FLAGS}"
FFLAGS="${COMMON_FLAGS}"
MAKEOPTS="-j12"
LC_MESSAGES=en_US.utf8

USE="X wayland i3wm icons apparmor pipewire standalone systemd flatpak gles2 alsa hardened multilib pulseaudio -d -fortran -rust -ipv6 -ada -qt5 -qt6"
VIDEO_CARDS="intel i915"
ACCEPT_LICENSE="*"
ACCEPT_KEYWORDS="~amd64"

FEATURES="getbinpkg binpkg-request-signature ccache parallel-fetch parallel-install"
CCACHE_DIR="/var/cache/ccache"
MAKECONF

# Official Gentoo binary package host — install prebuilt binpkgs where they
# match (USE/ABI), falling back to source. Speeds the install and later upgrades.
mkdir -p "${MOUNT}/etc/portage/binrepos.conf"
cat > "${MOUNT}/etc/portage/binrepos.conf/gentoobinhost.conf" <<'BINHOST'
[binhost]
priority = 9999
sync-uri = https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/x86-64/
BINHOST

# Portage builds happen in the /var/tmp/portage tmpfs (see fstab). Packages too
# big for RAM fall back to an on-disk build dir via package.env → notmpfs.conf.
mkdir -p "${MOUNT}/etc/portage/env"
cat > "${MOUNT}/etc/portage/env/notmpfs.conf" <<'NOTMPFS'
PORTAGE_TMPDIR="/var/tmp/notmpfs"
NOTMPFS
cat > "${MOUNT}/etc/portage/package.env" <<'PKGENV'
# Giant builds that can exceed RAM → build on disk instead of the tmpfs.
dev-lang/rust               notmpfs.conf
dev-lang/ghc                notmpfs.conf
dev-lang/spidermonkey       notmpfs.conf
sys-devel/llvm              notmpfs.conf
sys-devel/clang             notmpfs.conf
sys-devel/gcc               notmpfs.conf
llvm-core/llvm              notmpfs.conf
llvm-core/clang             notmpfs.conf
www-client/chromium         notmpfs.conf
www-client/firefox          notmpfs.conf
www-client/brave-browser    notmpfs.conf
mail-client/thunderbird     notmpfs.conf
app-office/libreoffice      notmpfs.conf
net-libs/webkit-gtk         notmpfs.conf
dev-qt/qtwebengine          notmpfs.conf
app-emulation/qemu          notmpfs.conf
PKGENV

cat > "${MOUNT}/etc/portage/package.use/gpg"            <<'EOF'
app-crypt/gnupg smartcard usb
EOF
cat > "${MOUNT}/etc/portage/package.use/iucode"         <<'EOF'
sys-firmware/intel-microcode initramfs
EOF
cat > "${MOUNT}/etc/portage/package.use/libsndfile"     <<'EOF'
media-libs/libsndfile minimal
EOF
cat > "${MOUNT}/etc/portage/package.use/networkmanager" <<'EOF'
net-misc/networkmanager iwd wifi
EOF
cat > "${MOUNT}/etc/portage/package.use/openssh"        <<'EOF'
net-misc/openssh -static
EOF
cat > "${MOUNT}/etc/portage/package.use/systemd"        <<'EOF'
sys-apps/systemd boot ukify homed repart sysupdate cryptsetup tpm
sys-kernel/installkernel systemd dracut ukify
EOF

# ── fstab / crypttab ─────────────────────────────────────────────
EFI_UUID=$(blkid -s UUID -o value "${PART_EFI}")

cat > "${MOUNT}/etc/fstab" <<FSTAB
# <device>            <dir>        <type>  <options>                                     <d> <p>
UUID=${EFI_UUID}      /boot        vfat    defaults,umask=0077                           0   2
UUID=${BTRFS_UUID}    /            btrfs   ${BTRFS_OPTS},subvol=@root                    0   0
UUID=${BTRFS_UUID}    /home        btrfs   ${BTRFS_OPTS},subvol=@home                    0   0
UUID=${BTRFS_UUID}    /.snapshots  btrfs   ${BTRFS_OPTS},subvol=@snapshots               0   0
# Portage build dir in RAM — keeps compile I/O OFF the dm-integrity root (which
# journals every write). Overflows to zram swap; giants fall back to disk via
# /etc/portage/package.env. (size is a share of RAM; tmpfs only uses what's written.)
tmpfs                 /var/tmp/portage  tmpfs  noatime,nosuid,nodev,mode=0775,uid=250,gid=250,size=60%  0 0
FSTAB

cat > "${MOUNT}/etc/crypttab" <<CRYPTTAB
# no 'discard' — TRIM is incompatible with dm-integrity
cryptroot  UUID=${LUKS_UUID}  none  luks
CRYPTTAB

info "fstab and crypttab written"

# ── Bind mounts for chroot ────────────────────────────────────────
for d in proc sys dev dev/pts; do
  mount --bind "/${d}" "${MOUNT}/${d}"
done
mount --make-rslave "${MOUNT}/sys"
mount --make-rslave "${MOUNT}/dev"

# ── Build chroot install script ───────────────────────────────────
step "Generating chroot script"

# Inject outer-script values as variable assignments (double-quoted → substituted)
cat > "${MOUNT}/root/install-chroot.sh" <<INJECT
#!/usr/bin/env bash
set -euo pipefail
LUKS_UUID="${LUKS_UUID}"
BTRFS_UUID="${BTRFS_UUID}"
DISK="${DISK}"
PART_EFI="${PART_EFI}"
PART_LUKS="${PART_LUKS}"
DOTS_REPO="${DOTS_REPO}"
ESP_SIZE="${ESP_SIZE}"
INJECT

# Append chroot body literally (single-quoted → no outer substitution)
cat >> "${MOUNT}/root/install-chroot.sh" <<'CHROOT_BODY'

RED='\033[0;31m' GRN='\033[0;32m' YLW='\033[0;33m'
CYN='\033[0;36m' BLD='\033[1m'    RST='\033[0m'
info() { printf "${GRN}[+]${RST} %s\n"           "$*"; }
step() { printf "\n${CYN}${BLD}━━ %s ${RST}\n"   "$*"; }
warn() { printf "${YLW}[!]${RST} %s\n"           "$*"; }
die()  { printf "${RED}[✗]${RST} %s\n" "$*" >&2; exit 1; }
ask()  { printf "${BLD}[?]${RST} %s "             "$*"; }

source /etc/profile
export PS1="(chroot) \$ "

# ── Timezone / locale ─────────────────────────────────────────────
step "Timezone and locale"
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
echo "UTC" > /etc/timezone

cat > /etc/locale.gen <<'LGEN'
en_US.UTF-8 UTF-8
LGEN
locale-gen
eselect locale set en_US.utf8
env-update && source /etc/profile

# ── Portage sync ─────────────────────────────────────────────────
step "Portage tree sync"
emerge-webrsync -q
emerge --sync --quiet

# ── Overlays ─────────────────────────────────────────────────────
step "Overlays"
emerge --oneshot --quiet app-eselect/eselect-repository dev-vcs/git

# brave-browser overlay
eselect repository enable brave-overlay 2>/dev/null || true
emaint sync -r brave-overlay -q 2>/dev/null || true

# hyprland extras (hyprlock, hypridle, etc.)
eselect repository enable hyprland 2>/dev/null || true
emaint sync -r hyprland -q 2>/dev/null || true

# ── ccache ───────────────────────────────────────────────────────
step "ccache"
emerge --oneshot --quiet dev-util/ccache
mkdir -p /var/cache/ccache
chmod 2775 /var/cache/ccache
cat > /var/cache/ccache/ccache.conf <<'CCACHECONF'
cache_dir = /var/cache/ccache
max_size = 10G
compression = true
CCACHECONF

# ── systemd stack ─────────────────────────────────────────────────
# The systemd stage3 ships systemd with default USE. Rebuild it with the flags
# from package.use (boot, ukify, homed, repart, sysupdate, cryptsetup, tpm) so
# bootctl / homectl / systemd-repart / ukify all become available.
step "systemd stack (boot · homed · repart · sysupdate · ukify)"
emerge --oneshot --quiet --newuse --changed-use \
  sys-apps/systemd \
  sys-kernel/installkernel

# ── Kernel + firmware ─────────────────────────────────────────────
step "Kernel (vanilla-kernel)"
emerge --quiet --noreplace \
  sys-kernel/vanilla-kernel \
  sys-kernel/linux-firmware \
  sys-firmware/intel-microcode

KVER=$(ls /lib/modules/ | sort -V | tail -1)
info "Kernel version: ${KVER}"

# ── initramfs → Unified Kernel Image (dracut) ────────────────────
step "UKI initramfs (dracut)"
emerge --quiet --noreplace sys-kernel/dracut

# The kernel cmdline is baked INTO the UKI — no bootloader config carries it.
# systemd-cryptsetup unlocks 'cryptroot' from /etc/crypttab (rd.luks.uuid).
mkdir -p /etc/kernel
cat > /etc/kernel/cmdline <<CMDLINE
rd.luks.uuid=${LUKS_UUID} root=UUID=${BTRFS_UUID} rootflags=subvol=@root rw quiet loglevel=3 mitigations=auto
CMDLINE

mkdir -p /etc/dracut.conf.d
cat > /etc/dracut.conf.d/10-systemd-uki.conf <<'DRACUT'
# systemd initrd (systemd-cryptsetup + crypttab), btrfs, and dm-integrity
add_dracutmodules+=" systemd crypt btrfs integrity "
hostonly="yes"
hostonly_cmdline="no"
compress="zstd"
uefi="yes"
DRACUT

# UKI naming 'gentoo_<ver>.efi' is what sysupdate matches (gentoo_@v.efi) and
# what gives A/B retention via InstancesMax=2.
mkdir -p /boot/EFI/Linux
dracut --force --uefi --kver "${KVER}" "/boot/EFI/Linux/gentoo_${KVER}.efi"
info "UKI: /boot/EFI/Linux/gentoo_${KVER}.efi"

# ── systemd-boot ─────────────────────────────────────────────────
step "systemd-boot (EFI)"
# bootctl ships with sys-apps/systemd[boot] (rebuilt above). NVRAM writes may
# fail inside the chroot — the ESP fallback path still boots.
bootctl install --esp-path=/boot \
  || warn "bootctl NVRAM entry failed — ESP fallback installed, fix with 'bootctl install' after reboot"

mkdir -p /boot/loader
cat > /boot/loader/loader.conf <<'LOADER'
timeout 5
console-mode keep
# entries are auto-discovered from /EFI/Linux/*.efi (the UKIs)
LOADER
info "systemd-boot installed; UKIs auto-discovered from /EFI/Linux"

# ── rebuild-uki helper ───────────────────────────────────────────
# A shell-free entry point that konkrit's kernel/boot-param modules call in
# place of Arch's `mkinitcpio -P`. It re-bakes the UKI from the base cmdline
# (/etc/kernel/cmdline) plus any drop-ins konkrit writes to
# /etc/kernel/cmdline.d/*.conf. Also covers microcode (dracut hostonly bundles
# host microcode) and Secure-Boot re-gen (stands in for `sbctl sign-all`).
mkdir -p /etc/kernel/cmdline.d
cat > /usr/local/sbin/rebuild-uki <<'RUKI'
#!/usr/bin/env bash
set -euo pipefail
KVER=$(ls /lib/modules/ | sort -V | tail -1)
base=$(tr '\n' ' ' < /etc/kernel/cmdline 2>/dev/null || true)
extra=""
if compgen -G "/etc/kernel/cmdline.d/*.conf" >/dev/null 2>&1; then
  extra=$(cat /etc/kernel/cmdline.d/*.conf | grep -vE '^\s*#' | tr '\n' ' ')
fi
exec dracut --force --uefi --kver "${KVER}" \
  --kernel-cmdline "${base} ${extra}" \
  "/boot/EFI/Linux/gentoo_${KVER}.efi"
RUKI
chmod +x /usr/local/sbin/rebuild-uki

# ── Background sd-sysupdate image rebuild around the sleep cycle ──
# sd-sysupdate manages VERSIONED UKIs (gentoo_<ver>.efi, InstancesMax=2) in the
# ESP for A/B rollback. Rebuilds are heavy, so we defer them to the sleep cycle:
# on RESUME (never mid-suspend — a torn write during S3 could brick the image),
# if the kernel or cmdline changed, mint a NEW versioned instance in the
# background at idle priority and let sd-sysupdate vacuum prune to InstancesMax.
cat > /usr/local/sbin/sysupdate-rebuild <<'SUR'
#!/usr/bin/env bash
set -euo pipefail
KVER=$(ls /lib/modules/ | sort -V | tail -1)
base=$(tr '\n' ' ' < /etc/kernel/cmdline 2>/dev/null || true)
extra=""
if compgen -G "/etc/kernel/cmdline.d/*.conf" >/dev/null 2>&1; then
  extra=$(cat /etc/kernel/cmdline.d/*.conf | grep -vE '^\s*#' | tr '\n' ' ')
fi
# New sd-sysupdate instance — version "<kver>.<UTC-stamp>" matches gentoo_@v.efi,
# so systemd-boot shows it as a new A/B entry and the prior image survives.
ver="${KVER}.$(date -u +%Y%m%d%H%M%S)"
dracut --force --uefi --kver "${KVER}" \
  --kernel-cmdline "${base} ${extra}" \
  "/boot/EFI/Linux/gentoo_${ver}.efi"
# Enforce InstancesMax from /etc/sysupdate.d/50-uki.conf; keep-newest-2 fallback.
systemd-sysupdate vacuum 2>/dev/null || true
ls -t /boot/EFI/Linux/gentoo_*.efi 2>/dev/null | tail -n +3 | xargs -r rm -f
SUR
chmod +x /usr/local/sbin/sysupdate-rebuild

cat > /etc/systemd/system/sysupdate-image.service <<'SUISVC'
[Unit]
Description=Rebuild the sd-sysupdate UKI image (background A/B instance)
ConditionPathExists=/usr/local/sbin/sysupdate-rebuild

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
ExecStart=/usr/local/sbin/sysupdate-rebuild
SUISVC

mkdir -p /usr/lib/systemd/system-sleep
cat > /usr/lib/systemd/system-sleep/50-sysupdate-image <<'SLEEPHOOK'
#!/usr/bin/env bash
# systemd-sleep hook: $1 = pre|post. On RESUME, rebuild the sd-sysupdate image
# in the background if it is stale w.r.t. the kernel or cmdline drop-ins.
[[ "$1" == "post" ]] || exit 0
KVER=$(ls /lib/modules/ | sort -V | tail -1)
newest_uki=$(ls -t /boot/EFI/Linux/gentoo_*.efi 2>/dev/null | head -1)
newest_src=$(ls -t /etc/kernel/cmdline /etc/kernel/cmdline.d/*.conf \
  "/lib/modules/${KVER}/modules.dep" 2>/dev/null | head -1)
if [[ -z "$newest_uki" || ( -n "$newest_src" && "$newest_src" -nt "$newest_uki" ) ]]; then
  systemctl start --no-block sysupdate-image.service
fi
SLEEPHOOK
chmod +x /usr/lib/systemd/system-sleep/50-sysupdate-image
info "Background sd-sysupdate image rebuild armed on resume (idle, stale-only)"

# ── Continuous update check + upgrade-on-suspend ─────────────────
# A low-priority timer keeps the Portage tree synced and flags when @world has
# updates. Suspending then kicks off the upgrade DETACHED (it freezes through S3
# and resumes on the next wake — a CPU can't compile during S3). getbinpkg keeps
# it fast by installing prebuilt binaries where they match.
cat > /usr/local/sbin/portage-check-updates <<'PCU'
#!/usr/bin/env bash
set -uo pipefail
flag=/var/lib/portage/.updates-pending
emerge --sync --quiet || exit 0
emaint sync -A -q 2>/dev/null || true
if emerge -puDN --quiet --color=n @world 2>/dev/null | grep -qE '^\[(ebuild|binary)'; then
  mkdir -p /var/lib/portage && touch "${flag}"
else
  rm -f "${flag}"
fi
PCU
chmod +x /usr/local/sbin/portage-check-updates

cat > /usr/local/sbin/portage-upgrade <<'PUP'
#!/usr/bin/env bash
set -uo pipefail
flag=/var/lib/portage/.updates-pending
[[ -e ${flag} ]] || exit 0
if emerge -uDN --keep-going --quiet @world; then
  rm -f "${flag}"
  emerge --quiet @preserved-rebuild || true
  # if the kernel moved, mint a fresh sd-sysupdate image instance
  [[ -x /usr/local/sbin/sysupdate-rebuild ]] && /usr/local/sbin/sysupdate-rebuild || true
fi
PUP
chmod +x /usr/local/sbin/portage-upgrade

cat > /etc/systemd/system/portage-sync.service <<'PSSVC'
[Unit]
Description=Sync Portage tree and flag available @world updates
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
ExecStart=/usr/local/sbin/portage-check-updates
PSSVC

cat > /etc/systemd/system/portage-sync.timer <<'PSTMR'
[Unit]
Description=Periodic Portage sync + update check

[Timer]
OnBootSec=15min
OnUnitActiveSec=6h
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
PSTMR

cat > /etc/systemd/system/portage-upgrade.service <<'PUSVC'
[Unit]
Description=Apply pending @world upgrade (background, on resume from suspend)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
ExecStart=/usr/local/sbin/portage-upgrade
PUSVC

cat > /usr/lib/systemd/system-sleep/60-portage-upgrade <<'SLEEPHOOK'
#!/usr/bin/env bash
# On SUSPEND (pre), if a @world upgrade is pending, start it DETACHED so it does
# not delay suspend. It freezes through S3 and continues on the next wake.
[[ "$1" == "pre" ]] || exit 0
[[ -e /var/lib/portage/.updates-pending ]] || exit 0
systemctl start --no-block portage-upgrade.service
SLEEPHOOK
chmod +x /usr/lib/systemd/system-sleep/60-portage-upgrade

systemctl enable portage-sync.timer
info "Update check (6h timer) + upgrade-on-suspend armed (getbinpkg-accelerated)"

# ── Build-in-RAM (keep Portage writes off dm-integrity) ──────────
# /var/tmp/portage is a tmpfs (fstab); zram gives it compressed-RAM swap so
# builds don't OOM without a swap partition. Only the giants in package.env
# (→ /var/tmp/notmpfs) and the final package merge touch the integrity device.
step "Build-in-RAM (zram + tmpfs build dir)"
install -d -m 0775 -o portage -g portage /var/tmp/portage /var/tmp/notmpfs
emerge --quiet --noreplace sys-apps/zram-generator \
  || warn "zram-generator emerge failed — tmpfs builds may OOM on low RAM"
cat > /etc/systemd/zram-generator.conf <<'ZRAM'
# Compressed RAM swap backing the /var/tmp/portage build tmpfs.
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
ZRAM

# ── System packages ───────────────────────────────────────────────
step "System packages"
emerge --quiet --noreplace \
  app-admin/sudo \
  app-crypt/gnupg \
  app-editors/neovim \
  app-misc/neofetch \
  app-shells/fish \
  app-shells/starship \
  dev-lang/sassc \
  dev-python/neovim-remote \
  dev-util/ccache \
  dev-util/gitlab-cli \
  media-fonts/nerdfonts \
  media-fonts/noto-emoji \
  net-misc/networkmanager \
  net-wireless/iwd \
  sys-apps/bat \
  sys-apps/eza \
  sys-apps/flatpak \
  sys-fs/btrfs-progs \
  www-client/brave-browser \
  x11-apps/xinit \
  x11-apps/xrandr \
  x11-base/xorg-server \
  x11-misc/autotiling \
  x11-misc/picom \
  x11-misc/polybar \
  x11-misc/rofi \
  x11-terms/alacritty \
  x11-themes/papirus-icon-theme \
  x11-wm/i3

# Hyprland + extras (best-effort — may require hyprland overlay)
emerge --quiet --noreplace gui-wm/hyprland gui-apps/waybar gui-apps/wofi \
  || warn "hyprland emerge had issues — install missing packages after boot"
emerge --quiet --noreplace \
  gui-apps/hyprpaper gui-apps/hyprlock gui-apps/hypridle \
  || warn "Some Hyprland extras unavailable — check the hyprland overlay after boot"

# ── Services ─────────────────────────────────────────────────────
# systemctl enable works offline in a chroot (it only writes symlinks).
# dbus + systemd-logind replace elogind and are enabled by systemd itself.
step "systemd services"
systemctl enable NetworkManager.service
systemctl enable systemd-homed.service        # LUKS-backed home dirs (homectl)
systemctl enable systemd-repart.service       # declarative partitioning on boot
systemctl enable systemd-sysupdate.timer      # A/B UKI update checks
systemctl enable systemd-boot-update.service  # keep systemd-boot in sync
systemctl enable bluetooth.service 2>/dev/null || true

# ── Flatpak ───────────────────────────────────────────────────────
flatpak remote-add --if-not-exists flathub \
  https://dl.flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true

# ── Root account + sudo ──────────────────────────────────────────
# The primary user is NOT created here: homectl needs a running systemd + a
# live D-Bus, which a chroot has neither of. It is provisioned on FIRST BOOT
# (gentoo-firstboot.service below); dotfiles are staged into /etc/skel so
# systemd-homed copies them into the new encrypted home on `homectl create`.
step "Root account"
# root_password comes from the afosi prompt (env). Fall back to interactive.
if [[ -n "${root_password:-}" ]]; then
  echo "root:${root_password}" | chpasswd
  info "Root password set (from afosi answer)"
else
  info "Set root password:"
  passwd root
fi

cat > /etc/sudoers.d/wheel <<'SUDOERS'
%wheel ALL=(ALL:ALL) ALL
SUDOERS
chmod 440 /etc/sudoers.d/wheel

# ── Hostname ─────────────────────────────────────────────────────
step "Hostname"
HOSTNAME_INPUT="${hostname:-gentoo}"   # from the afosi prompt (env)
echo "${HOSTNAME_INPUT}" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1     localhost
::1           localhost
127.0.1.1     ${HOSTNAME_INPUT}.localdomain  ${HOSTNAME_INPUT}
HOSTS

# ── Dotfiles (staged into /etc/skel) ─────────────────────────────
# Everything user-facing is written under /etc/skel; homed clones skel into the
# new user's encrypted home on first boot and fixes ownership automatically, so
# no chown here. Root-owned system files (portage, brave policy) stay in /etc.
step "Dotfiles from ${DOTS_REPO}"
DOTS_DIR="/etc/skel/dots"
git clone "${DOTS_REPO}" "${DOTS_DIR}"

# Portage config — overwrite embedded version with repo copy
info "Syncing portage config..."
cp "${DOTS_DIR}/Gentoo configuration/make.conf.intel" /etc/portage/make.conf
for f in "${DOTS_DIR}/Gentoo configuration/package.use/"*; do
  [[ -f "${f}" ]] && cp "${f}" "/etc/portage/package.use/$(basename "${f}")"
done

# Local overlay + custom profile (desktop/llvm/ccache)
info "Installing local overlay and custom profile..."
cp -r "${DOTS_DIR}/Gentoo configuration/local-repo" /var/db/repos/local
cat > /etc/portage/repos.conf/local.conf <<'EOF'
[local]
location = /var/db/repos/local
masters = gentoo
auto-sync = no
EOF
eselect profile set "local:default/linux/amd64/23.0/desktop/llvm/ccache"

# User config files → /etc/skel/.config/ (→ ~/.config on first boot)
info "Syncing user configs into /etc/skel..."
CFG_SRC="${DOTS_DIR}/files"
CFG_DST="/etc/skel/.config"
mkdir -p "${CFG_DST}"

for dir in alacritty dunst fish hypr i3 nvim polybar rofi neofetch gtk-2.0 gtk-3.0 zellij; do
  [[ -d "${CFG_SRC}/${dir}" ]] \
    && cp -r "${CFG_SRC}/${dir}" "${CFG_DST}/${dir}"
done

# picom lives under files/ directly (not a subdir)
if [[ -f "${CFG_SRC}/picom.conf" ]]; then
  mkdir -p "${CFG_DST}/picom"
  cp "${CFG_SRC}/picom.conf" "${CFG_DST}/picom/picom.conf"
fi

# Claude Code config lives under ~/.claude/, not ~/.config/
if [[ -d "${CFG_SRC}/claude" ]]; then
  CLAUDE_DST="/etc/skel/.claude"
  mkdir -p "${CLAUDE_DST}"
  cp "${CFG_SRC}/claude/settings.json"       "${CLAUDE_DST}/settings.json"
  cp "${CFG_SRC}/claude/settings.local.json" "${CLAUDE_DST}/settings.local.json" 2>/dev/null || true
  info "Claude Code config staged to /etc/skel/.claude/"
fi

# Brave policy (system-wide, requires root)
info "Applying Brave policy..."
BRAVE_POLICY_SRC="${CFG_SRC}/brave/policies"
if [[ -d "${BRAVE_POLICY_SRC}" ]]; then
  mkdir -p /etc/brave/policies
  cp -r "${BRAVE_POLICY_SRC}/managed"    /etc/brave/policies/managed
  cp -r "${BRAVE_POLICY_SRC}/recommended" /etc/brave/policies/recommended \
    2>/dev/null || true
  chmod -R 755 /etc/brave
  chmod    644 /etc/brave/policies/managed/*.json 2>/dev/null || true
  info "Brave policy installed to /etc/brave/policies/"
else
  warn "Brave policy directory not found in dots repo — skipping"
fi

# ── konkrit: hardening + Alpine Flatpak VM (agent-first tooling) ──
# Built here (installed system), RUN on first boot (after the user exists) by
# gentoo-firstboot.sh. NOTE: konkrit's catalog is Arch-targeted — a step that
# calls an absent program (pacman, mkinitcpio) makes konkrit abort its whole
# run on Gentoo, so the first-boot call is guarded and the catalog (shipped as
# ${DOTS_DIR}/.konkrit.yaml) is meant to be reviewed/curated for this host.
step "konkrit (build + Flatpak-VM prerequisites)"
# GURU community overlay — provides dev-libs/hardened_malloc (and other packages
# konkrit's catalog pulls that aren't in ::gentoo). Enable it so the first-boot
# `emerge dev-libs/hardened_malloc` resolves.
eselect repository enable guru 2>/dev/null || true
emaint sync -r guru -q 2>/dev/null || true
emerge --quiet --noreplace dev-lang/rust \
  || warn "rust emerge failed — konkrit will not build"
# Full-catalog choice pulls the Alpine/QEMU Flatpak-VM stack:
emerge --quiet --noreplace \
  app-emulation/libvirt \
  app-emulation/qemu \
  app-emulation/virt-manager \
  sys-firmware/edk2-ovmf \
  || warn "libvirt/qemu stack incomplete — the konkrit VM may not come up"
systemctl enable libvirtd.socket 2>/dev/null || true

if command -v cargo &>/dev/null; then
  info "Building konkrit (cargo, release)…"
  cargo install --quiet --git "${KONKRIT_REPO}" --root /usr/local \
    || warn "konkrit build failed — first-boot hardening will be skipped"
fi
mkdir -p /etc/konkrit
if [[ -f "${DOTS_DIR}/.konkrit.yaml" ]]; then
  cp "${DOTS_DIR}/.konkrit.yaml" /etc/konkrit/konkrit.yaml
  info "konkrit catalog installed to /etc/konkrit/konkrit.yaml"
else
  warn ".konkrit.yaml not found in dots repo — first-boot hardening will be skipped"
fi

# ── systemd-repart (installed-system, idempotent) ────────────────
# Same layout as the install-time definitions so systemd-repart.service is a
# no-op on an already-provisioned disk, but documents the layout and would
# re-add a missing ESP / grow into a bigger disk. No Format= on existing parts.
step "systemd-repart drop-ins"
mkdir -p /etc/repart.d
cat > /etc/repart.d/10-esp.conf <<EOF
[Partition]
Type=esp
Label=ESP
SizeMinBytes=${ESP_SIZE}
SizeMaxBytes=${ESP_SIZE}
EOF
cat > /etc/repart.d/20-cryptroot.conf <<'EOF'
[Partition]
Type=CA7D7CCB-63ED-4C53-861C-1742536059CC
Label=cryptroot
# btrfs lives INSIDE luks — repart only sees the LUKS blob and must not try to
# grow the filesystem. (Online growth = cryptsetup resize + btrfs fi resize.)
EOF

# ── systemd-sysupdate (A/B UKI retention) ────────────────────────
step "systemd-sysupdate drop-in"
mkdir -p /etc/sysupdate.d
cat > /etc/sysupdate.d/50-uki.conf <<'SYSUPD'
# A/B retention of kernel UKIs in the ESP. Gentoo builds UKIs locally, so there
# is no remote image server by default — point [Source] at your own https/dir
# mirror of gentoo_<version>.efi to enable pull-based updates. Until then this
# transfer enforces InstancesMax=2 over the locally-built UKIs (rollback slot).
[Transfer]
Verify=no

[Source]
Type=regular-file
Path=/var/lib/uki-src
MatchPattern=gentoo_@v.efi

[Target]
Type=regular-file
Path=/boot/EFI/Linux
MatchPattern=gentoo_@v.efi
Mode=0444
InstancesMax=2
SYSUPD

# ── First-boot user provisioning (systemd-homed) ─────────────────
step "First-boot user service"
cat > /usr/local/sbin/gentoo-firstboot.sh <<'FIRSTBOOT'
#!/usr/bin/env bash
set -euo pipefail
mark=/var/lib/gentoo-firstboot.done
[[ -e ${mark} ]] && exit 0

echo
echo "════════════════════════════════════════════════════════════"
echo "  First boot — create your systemd-homed user (LUKS home)"
echo "════════════════════════════════════════════════════════════"
U=""
while [[ -z ${U} ]]; do read -rp "  Username: " U; done

# homectl prompts for the new user's password and builds a per-user LUKS home
# image under /home/${U}.home, populated from /etc/skel (your dotfiles).
homectl create "${U}" \
  --storage=luks \
  --fs-type=btrfs \
  --shell=/usr/bin/fish \
  --member-of=wheel,audio,video,input,usb,plugdev,netdev

# ── konkrit: hardening + Alpine Flatpak VM ───────────────────────
# Point konkrit's {{user}} at the just-created account, then run the full
# catalog + VM. Guarded: konkrit's Arch-targeted steps may abort on Gentoo, and
# that must not block boot. Review /etc/konkrit/konkrit.yaml to curate modules.
if command -v konkrit &>/dev/null && [[ -f /etc/konkrit/konkrit.yaml ]]; then
  echo "  Applying konkrit hardening + Flatpak VM (this may take a while)…"
  sed -i "s|^  user: .*|  user: \"${U}\"|" /etc/konkrit/konkrit.yaml
  konkrit /etc/konkrit/konkrit.yaml \
    || echo "  [!] konkrit stopped early (Arch-targeted steps) — review /etc/konkrit"
fi

touch "${mark}"
systemctl disable gentoo-firstboot.service
echo "  User '${U}' created. Continuing boot…"
FIRSTBOOT
chmod +x /usr/local/sbin/gentoo-firstboot.sh

cat > /etc/systemd/system/gentoo-firstboot.service <<'UNIT'
[Unit]
Description=First-boot systemd-homed user provisioning
ConditionPathExists=!/var/lib/gentoo-firstboot.done
After=systemd-homed.service systemd-user-sessions.service
Wants=systemd-homed.service
Before=getty@tty1.service
Conflicts=getty@tty1.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/gentoo-firstboot.sh
StandardInput=tty
StandardOutput=tty
StandardError=tty
TTYPath=/dev/tty1
TTYReset=yes

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable gentoo-firstboot.service
info "First-boot user creation armed on tty1"

# ── Done ─────────────────────────────────────────────────────────
step "Chroot complete"
info "  Bootloader : systemd-boot + UKI (/boot/EFI/Linux/gentoo_*.efi)"
info "  User       : created on first boot via homectl (LUKS home)"
info "  Hostname   : ${HOSTNAME_INPUT}"
info "  Dotfiles   : staged in /etc/skel (→ ~/ on first login)"
echo ""
warn "Exit the chroot (Ctrl-D), then the outer script will unmount."
CHROOT_BODY

chmod +x "${MOUNT}/root/install-chroot.sh"

# ── Run chroot ───────────────────────────────────────────────────
step "Running chroot installation"
chroot "${MOUNT}" /usr/bin/env -i \
  HOME=/root \
  TERM="${TERM:-xterm}" \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  hostname="${hostname:-gentoo}" \
  root_password="${root_password:-}" \
  /root/install-chroot.sh

# ── Unmount ───────────────────────────────────────────────────────
step "Unmounting"
umount -R "${MOUNT}" 2>/dev/null || true
cryptsetup close cryptroot 2>/dev/null || true

echo ""
info "Done. Remove install media and reboot."
info "On first boot: tty1 prompts you to create your systemd-homed user."
info "After logging in, run:  nvim +Lazy +qa   to pull Neovim plugins."
