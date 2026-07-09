#!/usr/bin/env bash
# ================================================================
#  Gentoo automated FDE installer
#
#  Full-systemd, immutable-/usr Gentoo (per Poettering's "Fitting Everything
#  Together"). systemd-repart declaratively creates all partitions (DPS types):
#    · ESP (2 GiB)
#    · root  → LUKS2 (Encrypt=tpm2, no passphrase) → btrfs  [mutable /etc /var /home]
#              subvols @root @home @snapshots @builds
#    · swap  → linux-generic + crypttab random key (zswap-fronted)
#    · usr {a,b} + usr-verity {a,b} + usr-verity-sig {a,b}  [A/B dm-verity /usr]
#  /usr        : sealed read-only erofs + dm-verity image; roothash signed and
#                baked into the UKI as usrhash=. Toolchain ships as a systemd-sysext
#                (emerge.raw); updates RESEAL (emerge→staging→seal→sysupdate A/B).
#  Bootloader  : systemd-boot + UKI (ukify, signed)   Init: systemd
#  Extras      : systemd-repart · sysupdate (A/B) · systemd-homed · systemd-sysext
#  Window mgrs : i3 + Hyprland      Dotfiles: https://gitlab.com/TenTypekMatus/tokyonight-dots
#
#  Usage:
#    curl -fsSL https://gitlab.com/TenTypekMatus/tokyonight-dots/-/raw/main/install.sh | bash
#
#  Requirements: a SYSTEMD (>=254) live env with a TPM2 (or emulated swtpm) and:
#    systemd-repart, systemd-cryptenroll, cryptsetup, veritysetup, bootctl,
#    mkfs.btrfs, btrfs, sgdisk, curl, openssl (+ erofs-utils, ukify at seal time).
#  Env: TPM2_PCRS (empty = no PCR policy), USR_SIZE, INSTALL_STOP_AFTER (test hook).
# ================================================================
set -euo pipefail

# ── Constants ────────────────────────────────────────────────────
readonly DOTS_REPO="https://gitlab.com/TenTypekMatus/tokyonight-dots"
readonly DOTS_RAW="https://gitlab.com/TenTypekMatus/tokyonight-dots/-/raw/main"
readonly AFOSI_REPO="https://gitlab.com/agents-make-an-os/tooling/agent-first-os-installer.git"
readonly KONKRIT_REPO="https://gitlab.com/agents-make-an-os/tooling/konkrit.git"
readonly STAGE3_BASE="https://distfiles.gentoo.org/releases/amd64/autobuilds/20260705T170105Z/stage3-amd64-hardened-selinux-systemd-20260705T170105Z.tar.xz"
readonly STAGE3_PROFILE="current-stage3-amd64-hardened-selinux-systemd"
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

# ── Test checkpoint hook (inert unless INSTALL_STOP_AFTER matches) ─
# The VM test harness sets INSTALL_STOP_AFTER=<stage> to stop the installer at a
# stage boundary and inspect the on-disk result without running the multi-hour
# emerge/seal phase. Empty/unset never equals a stage name, so this is a no-op in
# normal use. The marker line is machine-parseable (tests/smoke.sh greps it).
checkpoint() {
  [[ "${INSTALL_STOP_AFTER:-}" == "$1" ]] || return 0
  printf '=== CHECKPOINT:%s ===\n' "$1"
  exit 0
}

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
# LVM tools are gone (full-systemd: repart owns the layout); TPM2 + verity are
# the new partition-time hard deps. The seal-time tools (mkfs.erofs, ukify) are
# checked separately just before sealing — they are not needed to reach the
# stage3 test checkpoint, and may be absent from a minimal live env.
for cmd in systemd-repart systemd-cryptenroll bootctl cryptsetup veritysetup \
           mkfs.btrfs btrfs sgdisk curl openssl; do
  command -v "${cmd}" &>/dev/null \
    || die "Missing: ${cmd}  (boot a systemd live ISO: SystemRescue / Gentoo LiveGUI / Arch)"
done

# repart Encrypt=tpm2 + CopyBlocks (used for the sealed /usr) need systemd >= 254.
_sdver=$(systemctl --version | awk 'NR==1{print $2}')
[[ "${_sdver}" -ge 254 ]] 2>/dev/null \
  || die "systemd ${_sdver} too old — need >= 254 for repart TPM2 + CopyBlocks"

# A TPM2 device is required for passphrase-free auto-unlock (VM: emulated swtpm).
[[ -e /dev/tpmrm0 || -e /dev/tpm0 ]] \
  || die "no TPM2 device (/dev/tpmrm0) — required for TPM2 unlock (VM needs an emulated swtpm)"

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

# Partitions are addressed by their repart GPT label (Discoverable Partitions
# Spec), not by numeric suffix — robust across NVMe/SATA and reorderings.
PART_EFI="/dev/disk/by-partlabel/ESP"
PART_ROOT="/dev/disk/by-partlabel/root"
PART_SWAP="/dev/disk/by-partlabel/swap"
PART_USR_A="/dev/disk/by-partlabel/usr_a"

# ── Signing keys (verity roothash + Secure Boot) ─────────────────
# Generated locally in the live env; private halves are NEVER sealed into the
# image. Real deployments must persist/manage these offline — the VM tests
# regenerate them per run. verity.crt signs the /usr dm-verity roothash;
# db.key/crt sign the UKI (ukify).
step "Signing keys (verity + Secure Boot)"
KEYDIR=$(mktemp -d /run/dots-keys.XXXXXX)
openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
  -keyout "${KEYDIR}/verity.key" -out "${KEYDIR}/verity.crt" \
  -subj "/CN=gentoo dm-verity" &>/dev/null
openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
  -keyout "${KEYDIR}/db.key" -out "${KEYDIR}/db.crt" \
  -subj "/CN=gentoo secureboot" &>/dev/null
info "keys in ${KEYDIR} (verity + SB db)"

# ── Partitioning (declarative, systemd-repart + TPM2 + DPS) ──────
step "Partitioning ${DISK} (systemd-repart + TPM2)"
sgdisk --zap-all "${DISK}" &>/dev/null   # clear stale GPT/LUKS headers first

RAM_GIB=$(awk '/MemTotal/{printf "%d", ($2/1024/1024)+1}' /proc/meminfo)
USR_SIZE="${USR_SIZE:-8G}"   # per-slot /usr image size (A and B); override for small disks
info "swap ${RAM_GIB}G · /usr slots ${USR_SIZE} (A/B) · root fills remainder"

# repart.d drop-ins are the single source of truth for the layout. The usr A/B
# image slots are created EMPTY here (the sealed erofs does not exist until after
# emerge); they are populated post-seal and by sysupdate thereafter. The SAME set
# is shipped into the installed system so systemd-repart.service is idempotent.
REPART_DEFS=$(mktemp -d)
_repartdef() { cat > "${REPART_DEFS}/$1"; }   # _repartdef FILE <<EOF … EOF

_repartdef 10-esp.conf <<EOF
[Partition]
Type=esp
Format=vfat
Label=ESP
SizeMinBytes=${ESP_SIZE}
SizeMaxBytes=${ESP_SIZE}
EOF
# root: LUKS2 + TPM2-sealed key, btrfs created inside. No size cap ⇒ grows into
# all space left after the fixed partitions.
_repartdef 20-root.conf <<EOF
[Partition]
Type=root
Label=root
Format=btrfs
Encrypt=tpm2
EOF
# swap: linux-generic (NOT Type=swap) so gpt-auto won't swapon it UNENCRYPTED;
# crypttab supplies the per-boot random-key crypto.
_repartdef 30-swap.conf <<EOF
[Partition]
Type=linux-generic
Label=swap
SizeMinBytes=${RAM_GIB}G
SizeMaxBytes=${RAM_GIB}G
EOF
# /usr A/B triplets (dm-verity image content written post-seal). A==B sizes.
for _slot in a b; do
  _repartdef "4${_slot}-usr-${_slot}.conf" <<EOF
[Partition]
Type=usr
Label=usr_${_slot}
SizeMinBytes=${USR_SIZE}
SizeMaxBytes=${USR_SIZE}
EOF
  _repartdef "5${_slot}-usrverity-${_slot}.conf" <<EOF
[Partition]
Type=usr-verity
Label=usr-verity_${_slot}
SizeMinBytes=512M
SizeMaxBytes=512M
EOF
  _repartdef "6${_slot}-usrveritysig-${_slot}.conf" <<EOF
[Partition]
Type=usr-verity-sig
Label=usr-verity-sig_${_slot}
SizeMinBytes=4M
SizeMaxBytes=4M
EOF
done

# --tpm2-pcrs="${TPM2_PCRS-7}": production binds PCR 7 (SecureBoot state, stable
# across kernel/UKI updates); the VM tests set TPM2_PCRS= (empty, no PCR policy)
# to dodge swtpm/OVMF PCR fragility. Note the '-' (not ':-'): an explicitly-empty
# value stays empty.
systemd-repart \
  --dry-run=no \
  --empty=force \
  --definitions="${REPART_DEFS}" \
  --tpm2-device=auto \
  --tpm2-pcrs="${TPM2_PCRS-7}" \
  "${DISK}"

partprobe "${DISK}" 2>/dev/null || true
udevadm settle
info "GPT + TPM2-encrypted root created"

# Recovery key: anti-lockout insurance if PCRs/firmware change. Printed to the
# console — save it. Adding a keyslot requires unlocking with an EXISTING
# credential first, so unlock via the TPM2 keyslot repart just enrolled
# (--unlock-tpm2-device=auto); </dev/null + timeout guarantee it can never block
# the headless install on a passphrase prompt.
step "TPM2 recovery key"
timeout 60 systemd-cryptenroll --unlock-tpm2-device=auto --recovery-key "${PART_ROOT}" </dev/null \
  || warn "recovery-key enroll skipped/failed — continuing (TPM2 unlock still works)"

# ── Reopen the TPM2-encrypted root + btrfs subvolumes ────────────
# repart created LUKS2 + enrolled the TPM2 + formatted btrfs INSIDE the volume,
# then closed it. Reopen via the just-enrolled TPM2 token (same boot ⇒ TPM state
# matches) — no passphrase. Do NOT mkfs; the btrfs already exists.
step "Reopen root (TPM2) + subvolumes"
systemd-cryptsetup attach cryptroot "${PART_ROOT}" - tpm2-device=auto </dev/null \
  || cryptsetup open --token-only "${PART_ROOT}" cryptroot </dev/null \
  || die "could not TPM2-unlock the just-created root"
BTRFS_UUID=$(blkid -s UUID -o value /dev/mapper/cryptroot)
info "root btrfs UUID: ${BTRFS_UUID}"

info "Creating subvolumes: @root @home @snapshots @builds"
mount /dev/mapper/cryptroot "${MOUNT}"
btrfs subvolume create "${MOUNT}/@root"
btrfs subvolume create "${MOUNT}/@home"
btrfs subvolume create "${MOUNT}/@snapshots"
btrfs subvolume create "${MOUNT}/@builds"     # emerge staging + Portage scratch
chattr +C "${MOUNT}/@builds" 2>/dev/null || true              # nodatacow
btrfs subvolume set-default "${MOUNT}/@root"   # gpt-auto mounts @root as / (no rootflags)
umount "${MOUNT}"

info "Mounting subvolumes for the build..."
mount -o "${BTRFS_OPTS},subvol=@root"      /dev/mapper/cryptroot "${MOUNT}"
mkdir -p "${MOUNT}"/{home,.snapshots,boot,var/tmp/notmpfs}
mount -o "${BTRFS_OPTS},subvol=@home"      /dev/mapper/cryptroot "${MOUNT}/home"
mount -o "${BTRFS_OPTS},subvol=@snapshots" /dev/mapper/cryptroot "${MOUNT}/.snapshots"
mount -o "${BTRFS_OPTS},subvol=@builds,nodatacow" /dev/mapper/cryptroot "${MOUNT}/var/tmp/notmpfs"
mount "${PART_EFI}" "${MOUNT}/boot"   # EFI partition doubles as /boot

# ── Install-time swap (transient random-key) ─────────────────────
# Plain dm-crypt, random key: re-keyed every boot, no persistent secret. Enabled
# now so install-time emerges have overflow. zswap (kernel cmdline) fronts it.
step "Encrypted swap (install-time)"
cryptsetup open --type plain --key-file /dev/urandom \
  --cipher aes-xts-plain64 --key-size 512 --sector-size 4096 \
  "${PART_SWAP}" cryptswap
mkswap -q /dev/mapper/cryptswap
swapon /dev/mapper/cryptswap
echo 1 > /sys/module/zswap/parameters/enabled 2>/dev/null || true   # best-effort now

# Test hook: stop here (partitioning + TPM2 encryption done, nothing merged yet).
checkpoint partition

# ── Stage3 ───────────────────────────────────────────────────────
step "Stage3 download"
_latest=$(curl -fsSL "${STAGE3_BASE}/${STAGE3_PROFILE}/latest-stage3-amd64-systemd.txt")
# The pointer file is PGP-clearsigned (…-----BEGIN PGP…) and has # comments —
# select the line that actually names the tarball, not armor/comment lines.
_s3file=$(grep -E '\.tar\.(xz|gz)' <<< "${_latest}" | awk '{print $1}' | head -1)
[[ -n "${_s3file}" ]] || die "could not parse stage3 filename from latest-stage3 pointer"
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

# The Portage scratch dir /var/tmp/notmpfs is the @builds subvol, already mounted
# during the reopen step above (no separate build LV any more).

# Test hook: stop here — full partitioning + TPM2 encryption + a base stage3 tree
# are on disk; the multi-hour emerge + /usr seal have NOT run.
checkpoint stage3

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
# / is auto-mounted by systemd-gpt-auto-generator (DPS root-x86-64, TPM2-unlocked,
# default subvol @root) — intentionally NO / entry. /usr is the read-only
# dm-verity image (usrhash= in the UKI); also NOT an fstab entry.
UUID=${EFI_UUID}        /boot            vfat  defaults,umask=0077                           0   2
UUID=${BTRFS_UUID}      /home            btrfs ${BTRFS_OPTS},subvol=@home                    0   0
UUID=${BTRFS_UUID}      /.snapshots      btrfs ${BTRFS_OPTS},subvol=@snapshots               0   0
# Portage scratch = @builds subvol (nodatacow); giants build here via package.env.
UUID=${BTRFS_UUID}      /var/tmp/notmpfs btrfs ${BTRFS_OPTS},subvol=@builds,nodatacow        0   0
# Small/medium Portage builds go to RAM; overflow → zswap → encrypted swap.
tmpfs                   /var/tmp/portage tmpfs noatime,nosuid,nodev,mode=0775,uid=250,gid=250,size=60% 0 0
# Encrypted swap (random key each boot); zswap fronts it (see kernel cmdline).
/dev/mapper/cryptswap   none             swap  sw                                           0   0
FSTAB

cat > "${MOUNT}/etc/crypttab" <<'CRYPTTAB'
# root: NOT here — systemd-gpt-auto-generator + systemd-cryptsetup TPM2-unlock it
#       from the LUKS2 systemd-tpm2 token. No entry, no passphrase.
# swap: fresh random key every boot (no persistence, no hibernation).
cryptswap  /dev/disk/by-partlabel/swap  /dev/urandom  swap,cipher=aes-xts-plain64,size=512,sector-size=4096
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

# Copy the signing keys into the chroot so the /usr seal (which runs inside the
# chroot, where erofs-utils + ukify are emerged) can sign the verity roothash and
# the UKI. /run/KEYDIR is not bind-mounted into the chroot, so stage it on-disk.
install -d -m 0700 "${MOUNT}/root/keys"
cp "${KEYDIR}"/{verity.key,verity.crt,db.key,db.crt} "${MOUNT}/root/keys/"

# Inject outer-script values as variable assignments (double-quoted → substituted)
cat > "${MOUNT}/root/install-chroot.sh" <<INJECT
#!/usr/bin/env bash
set -euo pipefail
BTRFS_UUID="${BTRFS_UUID}"
EFI_UUID="${EFI_UUID}"
DISK="${DISK}"
DOTS_REPO="${DOTS_REPO}"
ESP_SIZE="${ESP_SIZE}"
USR_SIZE="${USR_SIZE}"
TPM2_PCRS="${TPM2_PCRS-7}"
KEYDIR="/root/keys"          # keys staged above (chroot-local path)
INSTALL_STOP_AFTER="${INSTALL_STOP_AFTER:-}"
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

# ── initramfs config (dracut) — the UKI is assembled later, at seal time ──
# The UKI can only be built AFTER /usr is sealed: its cmdline must carry
# usrhash=<verity roothash>, unknown until then. Here we only emerge the tools
# and lay down the initrd config + base cmdline. The UKI is built by seal_usr().
step "initramfs config (dracut) + verity/erofs tools"
emerge --quiet --noreplace sys-kernel/dracut app-crypt/tpm2-tss sys-fs/erofs-utils \
  app-portage/portage-utils

# Stage the signing keys on the MUTABLE root (root-only) so the installed system
# can re-sign UKIs/roothashes on reseal. They live in /etc (never in sealed /usr).
install -d -m 0700 /etc/kernel/keys
cp "${KEYDIR}"/{verity.key,verity.crt,db.key,db.crt} /etc/kernel/keys/

mkdir -p /etc/kernel
# Base cmdline — NO root=/rd.luks/rd.lvm: systemd-gpt-auto-generator discovers the
# TPM2-encrypted root by DPS type on the boot disk; systemd-veritysetup mounts
# /usr from usrhash= (appended at seal). zswap fronts the encrypted swap.
cat > /etc/kernel/cmdline <<'CMDLINE'
rw zswap.enabled=1 zswap.compressor=zstd zswap.zpool=zsmalloc zswap.max_pool_percent=25 quiet loglevel=3 mitigations=auto
CMDLINE

mkdir -p /etc/dracut.conf.d
cat > /etc/dracut.conf.d/10-systemd-uki.conf <<'DRACUT'
# systemd initrd: systemd-cryptsetup (TPM2 unlock of root) + systemd-veritysetup
# (dm-verity /usr) + btrfs. erofs + dm-verity are forced in as drivers because
# /usr is mounted before modules living on /usr are reachable.
add_dracutmodules+=" systemd crypt btrfs tpm2-tss "
add_drivers+=" dm-verity erofs "
hostonly="yes"
hostonly_cmdline="no"
compress="zstd"
DRACUT

mkdir -p /boot/EFI/Linux

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
# Re-bakes the UKI from the base cmdline (/etc/kernel/cmdline) + konkrit's
# drop-ins (/etc/kernel/cmdline.d/*.conf), PRESERVING the current usrhash= (read
# from the running kernel's /proc/cmdline) so the dm-verity /usr binding survives
# a cmdline-only change. Assembled with ukify (not dracut --uefi) and signed with
# the staged Secure-Boot key. Lives in the sealed /usr; writes to /boot + reads
# keys from the mutable /etc. konkrit's kernel/boot-param modules call this.
mkdir -p /etc/kernel/cmdline.d
install -d -m 0755 /usr/lib/gentoo
cat > /usr/lib/gentoo/rebuild-uki <<'RUKI'
#!/usr/bin/env bash
set -euo pipefail
KVER=$(ls /lib/modules/ | sort -V | tail -1)
base=$(tr '\n' ' ' < /etc/kernel/cmdline 2>/dev/null || true)
extra=""
if compgen -G "/etc/kernel/cmdline.d/*.conf" >/dev/null 2>&1; then
  extra=$(cat /etc/kernel/cmdline.d/*.conf | grep -vE '^\s*#' | tr '\n' ' ')
fi
# Preserve the active dm-verity /usr binding.
usrhash=$(sed -n 's/.*\busrhash=\([0-9a-f]\+\).*/\1/p' /proc/cmdline)
[[ -n "${usrhash}" ]] && extra+=" usrhash=${usrhash}"
dracut --force --no-uefi --kver "${KVER}" /tmp/initrd.$$
ukify build --linux="/lib/modules/${KVER}/vmlinuz" --initrd="/tmp/initrd.$$" \
  --cmdline="${base} ${extra}" \
  --secureboot-private-key=/etc/kernel/keys/db.key \
  --secureboot-certificate=/etc/kernel/keys/db.crt \
  --output="/boot/EFI/Linux/gentoo_${KVER}.efi"
rm -f /tmp/initrd.$$
RUKI
chmod +x /usr/lib/gentoo/rebuild-uki
ln -sf /usr/lib/gentoo/rebuild-uki /usr/local/sbin/rebuild-uki 2>/dev/null || true

# ── Reseal update: emerge into staging → seal new /usr → sysupdate A/B ──
# On a read-only dm-verity /usr you cannot emerge in place or rebuild the UKI
# against the live tree. Instead the WHOLE update cycle is one idle-priority
# script: merge the emerge toolchain (sysext) → emerge @world into a staging
# root → seal the new /usr (erofs+verity+sign) + build a new UKI (new usrhash) →
# hand both to systemd-sysupdate for an A/B swap. gentoo-reseal.service runs it.
cat > /usr/lib/gentoo/sysext-update <<'RESEAL'
#!/usr/bin/env bash
set -euo pipefail
exec 9>/run/gentoo-reseal.lock; flock -n 9 || { echo "reseal already running"; exit 0; }

FLAG=/var/lib/portage/.updates-pending
[[ -e ${FLAG} ]] || { echo "no updates pending"; exit 0; }

STAGING=/var/tmp/notmpfs/staging          # @builds subvol (mutable, nodatacow)
KEYS=/etc/kernel/keys
SRC_USR=/var/lib/usr-src ; SRC_UKI=/var/lib/uki-src
KVER=$(ls /lib/modules/ | sort -V | tail -1)

cleanup(){ systemd-sysext unmerge 2>/dev/null || true; }
trap cleanup EXIT

echo "[reseal] merging emerge toolchain (sysext)…"
systemd-sysext merge

echo "[reseal] emerging @world into staging (live /usr untouched)…"
rm -rf "${STAGING}"; mkdir -p "${STAGING}" "${SRC_USR}" "${SRC_UKI}"
emerge --root="${STAGING}" --config-root="${STAGING}" -uDN --keep-going @world
emerge --root="${STAGING}" @preserved-rebuild || true

echo "[reseal] sealing new /usr (erofs + dm-verity + sign)…"
ver="${KVER}.$(date -u +%Y%m%d%H%M%S)"
erofs="${SRC_USR}/usr_${ver}.erofs"
mkfs.erofs -zlz4hc -T0 --all-root "${erofs}" "${STAGING}/usr"
roothash=$(veritysetup format "${erofs}" "${SRC_USR}/usr_${ver}.verity" | awk '/Root hash/{print $3}')
openssl smime -sign -nocerts -noattr -binary -in <(printf '%s' "${roothash}") \
  -inkey "${KEYS}/verity.key" -signer "${KEYS}/verity.crt" -outform der \
  > "${SRC_USR}/usr_${ver}.p7s"
printf '{"rootHash":"%s","signature":"%s"}' \
  "${roothash}" "$(base64 -w0 "${SRC_USR}/usr_${ver}.p7s")" \
  > "${SRC_USR}/usr_${ver}.verity-sig"

echo "[reseal] building UKI (usrhash=${roothash})…"
base=$(tr '\n' ' ' < /etc/kernel/cmdline)
dracut --force --no-uefi --kver "${KVER}" "/tmp/reseal-initrd.$$"
ukify build --linux="/lib/modules/${KVER}/vmlinuz" --initrd="/tmp/reseal-initrd.$$" \
  --cmdline="${base} usrhash=${roothash}" \
  --secureboot-private-key="${KEYS}/db.key" --secureboot-certificate="${KEYS}/db.crt" \
  --output="${SRC_UKI}/gentoo_${ver}.efi"
rm -f "/tmp/reseal-initrd.$$"

echo "[reseal] systemd-sysupdate A/B swap…"
systemd-sysupdate update
rm -f "${FLAG}"
echo "[reseal] done — reboot into the new slot; the prior slot remains for rollback."
RESEAL
chmod +x /usr/lib/gentoo/sysext-update

cat > /etc/systemd/system/gentoo-reseal.service <<'RESVC'
[Unit]
Description=Reseal the OS /usr image and stage an A/B systemd-sysupdate
Wants=network-online.target
After=network-online.target
ConditionPathExists=/usr/lib/gentoo/sysext-update

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
ExecStart=/usr/lib/gentoo/sysext-update
RESVC
info "Reseal update path armed (gentoo-reseal.service → sysext-update)"

# ── Continuous update check + reseal-on-suspend ──────────────────
# A low-priority timer keeps the Portage tree synced and flags when @world has
# updates. Suspending then kicks off the RESEAL detached (gentoo-reseal.service):
# it builds the next /usr image and stages an A/B systemd-sysupdate. getbinpkg
# keeps the emerge-into-staging fast where prebuilt binaries match.
cat > /usr/lib/gentoo/portage-check-updates <<'PCU'
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
chmod +x /usr/lib/gentoo/portage-check-updates

cat > /etc/systemd/system/portage-sync.service <<'PSSVC'
[Unit]
Description=Sync Portage tree and flag available @world updates
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
ExecStart=/usr/lib/gentoo/portage-check-updates
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

mkdir -p /usr/lib/systemd/system-sleep
cat > /usr/lib/systemd/system-sleep/60-portage-reseal <<'SLEEPHOOK'
#!/usr/bin/env bash
# On SUSPEND (pre), if a @world upgrade is pending, start the RESEAL detached so
# it does not delay suspend. It freezes through S3 and continues on the next wake
# (a CPU cannot compile during S3), building the next /usr image + A/B sysupdate.
[[ "$1" == "pre" ]] || exit 0
[[ -e /var/lib/portage/.updates-pending ]] || exit 0
systemctl start --no-block gentoo-reseal.service
SLEEPHOOK
chmod +x /usr/lib/systemd/system-sleep/60-portage-reseal

systemctl enable portage-sync.timer
info "Update check (6h timer) + reseal-on-suspend armed (getbinpkg-accelerated)"

# ── Build offload (@builds subvol + zswap swap) ──────────────────
# Small/medium builds use the /var/tmp/portage tmpfs (fstab). Giants in
# package.env build on the @builds btrfs subvol (nodatacow) mounted at
# /var/tmp/notmpfs. zswap (kernel cmdline) fronts the encrypted swap, so tmpfs
# overflow compresses in RAM before hitting disk. No LVM any more.
step "Build offload (@builds + zswap)"
# /var/tmp/portage: tmpfs mountpoint. /var/tmp/notmpfs: the @builds subvol —
# chown its root so Portage (uid/gid 250) can write there.
install -d -m 0775 -o portage -g portage /var/tmp/portage
chown portage:portage /var/tmp/notmpfs
chmod 0775 /var/tmp/notmpfs

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
systemctl enable systemd-sysupdate.timer      # A/B UKI + /usr image update checks
systemctl enable systemd-boot-update.service  # keep systemd-boot in sync
systemctl enable systemd-bless-boot.service 2>/dev/null || true  # auto-rollback a bad A/B boot
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
step "systemd-repart drop-ins (installed system)"
mkdir -p /etc/repart.d
# Byte-identical to the install-time set so systemd-repart.service is idempotent:
# it adopts existing partitions by Type+Label and NEVER reformats/re-encrypts a
# non-empty partition (the root already has a LUKS2 header, the usr slots content).
_RAM_GIB=$(awk '/MemTotal/{printf "%d", ($2/1024/1024)+1}' /proc/meminfo)
cat > /etc/repart.d/10-esp.conf <<EOF
[Partition]
Type=esp
Format=vfat
Label=ESP
SizeMinBytes=${ESP_SIZE}
SizeMaxBytes=${ESP_SIZE}
EOF
cat > /etc/repart.d/20-root.conf <<'EOF'
[Partition]
Type=root
Label=root
Format=btrfs
Encrypt=tpm2
EOF
cat > /etc/repart.d/30-swap.conf <<EOF
[Partition]
Type=linux-generic
Label=swap
SizeMinBytes=${_RAM_GIB}G
SizeMaxBytes=${_RAM_GIB}G
EOF
for _slot in a b; do
  cat > "/etc/repart.d/4${_slot}-usr-${_slot}.conf" <<EOF
[Partition]
Type=usr
Label=usr_${_slot}
SizeMinBytes=${USR_SIZE}
SizeMaxBytes=${USR_SIZE}
EOF
  cat > "/etc/repart.d/5${_slot}-usrverity-${_slot}.conf" <<EOF
[Partition]
Type=usr-verity
Label=usr-verity_${_slot}
SizeMinBytes=512M
SizeMaxBytes=512M
EOF
  cat > "/etc/repart.d/6${_slot}-usrveritysig-${_slot}.conf" <<EOF
[Partition]
Type=usr-verity-sig
Label=usr-verity-sig_${_slot}
SizeMinBytes=4M
SizeMaxBytes=4M
EOF
done

# ── systemd-sysupdate (A/B retention: UKI + /usr verity triplet) ──
step "systemd-sysupdate drop-ins"
mkdir -p /etc/sysupdate.d /var/lib/uki-src /var/lib/usr-src
# All four transfers share @v so one `systemd-sysupdate update` is version-
# consistent: new /usr image+verity+sig into the inactive slot, new UKI into ESP.
cat > /etc/sysupdate.d/50-uki.conf <<'SYSUPD'
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
cat > /etc/sysupdate.d/60-usr.conf <<'SYSUPD'
[Transfer]
Verify=no
[Source]
Type=regular-file
Path=/var/lib/usr-src
MatchPattern=usr_@v.erofs
[Target]
Type=partition
Path=auto
MatchPattern=usr_@v
MatchPartitionType=usr
ReadOnly=1
InstancesMax=2
SYSUPD
cat > /etc/sysupdate.d/61-usr-verity.conf <<'SYSUPD'
[Transfer]
Verify=no
[Source]
Type=regular-file
Path=/var/lib/usr-src
MatchPattern=usr_@v.verity
[Target]
Type=partition
Path=auto
MatchPattern=usr_@v
MatchPartitionType=usr-verity
ReadOnly=1
InstancesMax=2
SYSUPD
cat > /etc/sysupdate.d/62-usr-verity-sig.conf <<'SYSUPD'
[Transfer]
Verify=no
[Source]
Type=regular-file
Path=/var/lib/usr-src
MatchPattern=usr_@v.verity-sig
[Target]
Type=partition
Path=auto
MatchPattern=usr_@v
MatchPartitionType=usr-verity-sig
ReadOnly=1
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

# ── Seal /usr into a signed dm-verity image + build the UKI ──────
# Everything is emerged and configured; now (1) split the Portage toolchain into
# a systemd-sysext so the base /usr stays lean, (2) seal the base /usr into a
# read-only erofs + dm-verity image, sign it, write it into the usr_a triplet,
# and (3) build the UKI whose cmdline carries usrhash=<roothash>. Runs here in
# the chroot where erofs-utils/ukify/veritysetup are emerged and /dev (the target
# block devices) is bind-mounted.
step "Seal immutable /usr (erofs + dm-verity) + UKI"

# usr-merge sanity — the split is only safe if these are symlinks into /usr.
for _l in /bin /sbin /lib /lib64; do
  [[ -L "${_l}" ]] || die "not usr-merged (${_l} is not a symlink) — cannot seal /usr"
done
# SYSEXT_LEVEL decouples sysext matching from the per-build VERSION_ID.
grep -q '^SYSEXT_LEVEL=' /usr/lib/os-release || echo 'SYSEXT_LEVEL=1' >> /usr/lib/os-release

_WORK=$(mktemp -d)
KVER=$(ls /lib/modules/ | sort -V | tail -1)
VER="${KVER}.0"

# (1) emerge toolchain sysext — collect the toolchain's /usr files, pack them into
#     an erofs extension, then prune them from the base /usr.
_FL="${_WORK}/emerge.files"; : > "${_FL}"
for _pkg in sys-apps/portage sys-devel/gcc sys-devel/binutils sys-devel/make \
            dev-util/ccache dev-vcs/git app-portage/portage-utils app-portage/gentoolkit; do
  qlist -C "${_pkg}" 2>/dev/null | grep '^/usr/' >> "${_FL}" || true
done
sort -u "${_FL}" -o "${_FL}"
_SX="${_WORK}/emerge-root"
install -d -m 0755 "${_SX}/usr/lib/extension-release.d"
tar --numeric-owner -C / -cpf "${_WORK}/sx.tar" -T "${_FL}" 2>/dev/null || true
tar -C "${_SX}" -xpf "${_WORK}/sx.tar" 2>/dev/null || true
cat > "${_SX}/usr/lib/extension-release.d/extension-release.emerge" <<'EREL'
ID=gentoo
SYSEXT_LEVEL=1
ARCHITECTURE=x86-64
EREL
mkdir -p /var/lib/extensions
mkfs.erofs -zlz4hc -T0 --all-root /var/lib/extensions/emerge.raw "${_SX}" >/dev/null
while read -r _f; do rm -f "${_f}" 2>/dev/null || true; done < "${_FL}"
info "emerge sysext → /var/lib/extensions/emerge.raw ($(wc -l < "${_FL}") files split out)"

# (2) seal the lean base /usr
mkfs.erofs -zlz4hc -T0 --all-root "${_WORK}/usr.erofs" /usr >/dev/null
ROOTHASH=$(veritysetup format "${_WORK}/usr.erofs" "${_WORK}/usr.verity" | awk '/Root hash/{print $3}')
openssl smime -sign -nocerts -noattr -binary -in <(printf '%s' "${ROOTHASH}") \
  -inkey "${KEYDIR}/verity.key" -signer "${KEYDIR}/verity.crt" -outform der > "${_WORK}/usr.p7s"
printf '{"rootHash":"%s","signature":"%s"}' \
  "${ROOTHASH}" "$(base64 -w0 "${_WORK}/usr.p7s")" > "${_WORK}/usr.verity-sig"
info "usr dm-verity roothash: ${ROOTHASH}"

# (3) write the image triplet into usr_a, then build the UKI with usrhash=
dd if="${_WORK}/usr.erofs"       of=/dev/disk/by-partlabel/usr_a            bs=4M conv=fsync status=none
dd if="${_WORK}/usr.verity"      of=/dev/disk/by-partlabel/usr-verity_a     bs=4M conv=fsync status=none
dd if="${_WORK}/usr.verity-sig"  of=/dev/disk/by-partlabel/usr-verity-sig_a bs=1M conv=fsync status=none
_BASE=$(tr '\n' ' ' < /etc/kernel/cmdline)
dracut --force --no-uefi --kver "${KVER}" "${_WORK}/initrd"
ukify build --linux="/lib/modules/${KVER}/vmlinuz" --initrd="${_WORK}/initrd" \
  --cmdline="${_BASE} usrhash=${ROOTHASH}" \
  --os-release="@/usr/lib/os-release" \
  --secureboot-private-key="${KEYDIR}/db.key" --secureboot-certificate="${KEYDIR}/db.crt" \
  --output="/boot/EFI/Linux/gentoo_${VER}.efi"
cp "${_WORK}/usr.erofs" "/var/lib/usr-src/usr_${VER}.erofs" 2>/dev/null || true
cp "/boot/EFI/Linux/gentoo_${VER}.efi" /var/lib/uki-src/ 2>/dev/null || true
rm -rf "${_WORK}"
info "UKI: /boot/EFI/Linux/gentoo_${VER}.efi (usrhash embedded)"

# ── Done ─────────────────────────────────────────────────────────
step "Chroot complete"
info "  Bootloader : systemd-boot + UKI (/boot/EFI/Linux/gentoo_*.efi)"
info "  /usr       : sealed read-only dm-verity image (usr_a)"
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
umount -R "${MOUNT}" 2>/dev/null || true          # also unmounts /var/tmp/notmpfs
swapoff /dev/mapper/cryptswap 2>/dev/null || true
cryptsetup close cryptswap 2>/dev/null || true
cryptsetup close cryptroot 2>/dev/null || true
rm -rf "${KEYDIR}" 2>/dev/null || true             # wipe the live-env key copy

echo ""
info "Done. Remove install media and reboot."
info "On first boot: tty1 prompts you to create your systemd-homed user."
info "After logging in, run:  nvim +Lazy +qa   to pull Neovim plugins."
