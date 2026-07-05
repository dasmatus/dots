#!/usr/bin/env bash
# ================================================================
#  Gentoo automated FDE installer
#
#  Partition layout : GPT | 512 MiB EFI (FAT32) | LUKS2 → btrfs
#  btrfs subvolumes : @root  @home  @snapshots
#  Bootloader       : Limine (EFI-native, no BIOS MBR)
#  Init system      : OpenRC + elogind
#  Window managers  : i3  +  Hyprland
#  Dotfiles         : https://gitlab.com/TenTypekMatus/tokyonight-dots
#
#  Usage:
#    curl -fsSL https://gitlab.com/TenTypekMatus/tokyonight-dots/-/raw/main/install.sh | bash
#
#  Requirements: Gentoo admin LiveCD (or any live env with
#    sgdisk, cryptsetup, mkfs.btrfs, btrfs, mkfs.fat, curl)
# ================================================================
set -euo pipefail

# ── Constants ────────────────────────────────────────────────────
readonly DOTS_REPO="https://gitlab.com/TenTypekMatus/tokyonight-dots"
readonly STAGE3_BASE="https://distfiles.gentoo.org/releases/amd64/autobuilds"
readonly STAGE3_PROFILE="current-stage3-amd64-openrc"
readonly MOUNT="/mnt"
readonly BTRFS_OPTS="noatime,compress=zstd:1,space_cache=v2"

# ── Colours + helpers ────────────────────────────────────────────
RED='\033[0;31m' GRN='\033[0;32m' YLW='\033[0;33m'
CYN='\033[0;36m' BLD='\033[1m'    RST='\033[0m'
info() { printf "${GRN}[+]${RST} %s\n"           "$*"; }
step() { printf "\n${CYN}${BLD}━━ %s ${RST}\n"   "$*"; }
warn() { printf "${YLW}[!]${RST} %s\n"           "$*"; }
die()  { printf "${RED}[✗]${RST} %s\n" "$*" >&2; exit 1; }
ask()  { printf "${BLD}[?]${RST} %s "             "$*"; }

# ── Pre-flight ───────────────────────────────────────────────────
step "Pre-flight checks"

[[ $EUID -eq 0 ]]          || die "Must run as root"
[[ -d /sys/firmware/efi ]] || die "UEFI not detected — EFI boot required"

for cmd in sgdisk cryptsetup mkfs.fat mkfs.btrfs btrfs curl; do
  command -v "${cmd}" &>/dev/null \
    || die "Missing: ${cmd}  (use the Gentoo admin LiveCD)"
done

# ── Disk selection ───────────────────────────────────────────────
step "Disk selection"

mapfile -t _RAW_DISKS < <(
  lsblk -dn -o NAME,SIZE,TYPE | awk '$3=="disk"{print "/dev/"$1, $2}'
)

DISKS=()
for entry in "${_RAW_DISKS[@]}"; do
  dev=$(awk '{print $1}' <<< "${entry}")
  size=$(awk '{print $2}' <<< "${entry}")
  # Skip if any partition on this disk is currently mounted
  if lsblk -no MOUNTPOINTS "${dev}" 2>/dev/null | grep -qE '^/'; then
    continue
  fi
  DISKS+=("${dev} ${size}")
done

# Sort by size descending (human-sort on the size column)
mapfile -t DISKS < <(printf '%s\n' "${DISKS[@]}" | sort -k2 -rh)

[[ ${#DISKS[@]} -gt 0 ]] || die "No unmounted disks found"

echo ""
echo "  Unmounted disks (largest first):"
for i in "${!DISKS[@]}"; do
  read -r dev size <<< "${DISKS[$i]}"
  printf "    %d)  %-20s %s\n" "$((i+1))" "${dev}" "${size}"
done
echo ""
ask "Select disk number [1]:"
read -r _choice
_choice="${_choice:-1}"
[[ "${_choice}" =~ ^[0-9]+$ ]] \
  && (( _choice >= 1 && _choice <= ${#DISKS[@]} )) \
  || die "Invalid selection"

DISK=$(awk '{print $1}' <<< "${DISKS[$((_choice-1))]}")
info "Target disk: ${DISK}"

echo ""
warn "ALL DATA ON ${DISK} WILL BE PERMANENTLY ERASED."
ask "Type 'yes' to confirm:"
read -r _confirm
[[ "${_confirm}" == "yes" ]] || die "Aborted"

# NVMe / eMMC partition suffix is 'p', SATA/SAS use plain numbers
if [[ "${DISK}" =~ nvme|mmcblk ]]; then
  PART_EFI="${DISK}p1"
  PART_LUKS="${DISK}p2"
else
  PART_EFI="${DISK}1"
  PART_LUKS="${DISK}2"
fi

# ── Partitioning ─────────────────────────────────────────────────
step "Partitioning ${DISK}"
sgdisk --zap-all "${DISK}" &>/dev/null
sgdisk \
  -n 1:0:+512M  -t 1:ef00 -c 1:"EFI System" \
  -n 2:0:0      -t 2:8309 -c 2:"LUKS"       \
  "${DISK}"
partprobe "${DISK}"
udevadm settle
info "GPT created: ${PART_EFI} (512 MiB EFI)  ${PART_LUKS} (LUKS)"

# ── LUKS2 ────────────────────────────────────────────────────────
step "LUKS2 setup"
info "Formatting ${PART_LUKS} — you'll enter the passphrase twice."
cryptsetup luksFormat \
  --type        luks2          \
  --cipher      aes-xts-plain64 \
  --key-size    512            \
  --hash        sha512         \
  --pbkdf       argon2id       \
  --iter-time   4000           \
  "${PART_LUKS}"

info "Opening LUKS container as 'cryptroot'..."
cryptsetup open "${PART_LUKS}" cryptroot

LUKS_UUID=$(cryptsetup luksUUID "${PART_LUKS}")
info "LUKS UUID: ${LUKS_UUID}"

# ── btrfs filesystem ─────────────────────────────────────────────
step "btrfs + subvolumes"
mkfs.fat -F32 -n EFI "${PART_EFI}" &>/dev/null
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
_latest=$(curl -fsSL "${STAGE3_BASE}/${STAGE3_PROFILE}/latest-stage3-amd64-openrc.txt")
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

USE="X wayland i3wm icons apparmor pipewire standalone elogind flatpak gles2 alsa hardened multilib pulseaudio -d -fortran -rust -ipv6 -ada -qt5 -qt6"
VIDEO_CARDS="intel i915"
ACCEPT_LICENSE="*"
ACCEPT_KEYWORDS="~amd64"

FEATURES="ccache parallel-fetch parallel-install"
CCACHE_DIR="/var/cache/ccache"
MAKECONF

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
cat > "${MOUNT}/etc/portage/package.use/systemd-utils"  <<'EOF'
sys-apps/systemd-utils udev tmpfiles
EOF

# ── fstab / crypttab ─────────────────────────────────────────────
EFI_UUID=$(blkid -s UUID -o value "${PART_EFI}")

cat > "${MOUNT}/etc/fstab" <<FSTAB
# <device>            <dir>        <type>  <options>                                     <d> <p>
UUID=${EFI_UUID}      /boot        vfat    defaults,umask=0077                           0   2
UUID=${BTRFS_UUID}    /            btrfs   ${BTRFS_OPTS},subvol=@root                    0   0
UUID=${BTRFS_UUID}    /home        btrfs   ${BTRFS_OPTS},subvol=@home                    0   0
UUID=${BTRFS_UUID}    /.snapshots  btrfs   ${BTRFS_OPTS},subvol=@snapshots               0   0
FSTAB

cat > "${MOUNT}/etc/crypttab" <<CRYPTTAB
cryptroot  UUID=${LUKS_UUID}  none  luks,discard
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

# ── Kernel + firmware ─────────────────────────────────────────────
step "Kernel (vanilla-kernel)"
emerge --quiet --noreplace \
  sys-kernel/vanilla-kernel \
  sys-kernel/linux-firmware \
  sys-firmware/intel-microcode

KVER=$(ls /lib/modules/ | sort -V | tail -1)
info "Kernel version: ${KVER}"

# ── dracut initramfs ─────────────────────────────────────────────
step "initramfs (dracut)"
emerge --quiet --noreplace sys-kernel/dracut

mkdir -p /etc/dracut.conf.d
cat > /etc/dracut.conf.d/10-crypt.conf <<'DRACUT'
add_dracutmodules+=" crypt btrfs "
hostonly="yes"
hostonly_cmdline="yes"
compress="zstd"
DRACUT

dracut --force --kver "${KVER}" "/boot/initramfs-${KVER}.img"
info "initramfs: /boot/initramfs-${KVER}.img"

# ── Limine bootloader ─────────────────────────────────────────────
step "Limine (EFI)"
emerge --quiet --noreplace sys-boot/limine sys-boot/efibootmgr

mkdir -p /boot/EFI/limine /boot/EFI/BOOT
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/limine.efi
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI   # fallback entry

VMLINUZ=$(ls /boot/vmlinuz-* 2>/dev/null | sort -V | tail -1 | xargs basename)

cat > /boot/limine.conf <<LIMCONF
timeout: 5

/Gentoo Linux
    protocol: linux
    path: boot():/${VMLINUZ}
    cmdline: rd.luks.uuid=${LUKS_UUID} rd.luks.name=${LUKS_UUID}=cryptroot root=UUID=${BTRFS_UUID} rootflags=subvol=@root rw quiet loglevel=3 mitigations=auto
    module_path: boot():/initramfs-${KVER}.img
LIMCONF

info "Limine config: /boot/limine.conf"

efibootmgr \
  --create \
  --disk "${DISK}" \
  --part 1 \
  --loader '\EFI\limine\limine.efi' \
  --label 'Limine' \
  --unicode \
  || warn "efibootmgr failed — add the EFI entry manually after reboot"

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
step "OpenRC services"
rc-update add NetworkManager default
rc-update add elogind boot
rc-update add dbus default
rc-update add bluetooth default 2>/dev/null || true

# ── Flatpak ───────────────────────────────────────────────────────
flatpak remote-add --if-not-exists flathub \
  https://dl.flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true

# ── User account ─────────────────────────────────────────────────
step "User account"
ask "Username:"
read -r USERNAME
useradd -m \
  -G wheel,audio,video,usb,plugdev,input,seat,netdev \
  -s /usr/bin/fish \
  "${USERNAME}"
info "Set password for ${USERNAME}:"
passwd "${USERNAME}"
info "Set root password:"
passwd root

cat > /etc/sudoers.d/wheel <<'SUDOERS'
%wheel ALL=(ALL:ALL) ALL
SUDOERS
chmod 440 /etc/sudoers.d/wheel

# ── Hostname ─────────────────────────────────────────────────────
step "Hostname"
ask "Hostname [gentoo]:"
read -r HOSTNAME_INPUT
HOSTNAME_INPUT="${HOSTNAME_INPUT:-gentoo}"
echo "${HOSTNAME_INPUT}" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1     localhost
::1           localhost
127.0.1.1     ${HOSTNAME_INPUT}.localdomain  ${HOSTNAME_INPUT}
HOSTS

# ── Dotfiles ─────────────────────────────────────────────────────
step "Dotfiles from ${DOTS_REPO}"
DOTS_DIR="/home/${USERNAME}/dots"
git clone "${DOTS_REPO}" "${DOTS_DIR}"
chown -R "${USERNAME}:${USERNAME}" "${DOTS_DIR}"

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

# User config files → ~/.config/
info "Syncing user configs..."
CFG_SRC="${DOTS_DIR}/Configuration files"
CFG_DST="/home/${USERNAME}/.config"
mkdir -p "${CFG_DST}"

for dir in alacritty dunst fish hypr i3 nvim polybar rofi neofetch gtk-2.0 gtk-3.0 zellij; do
  [[ -d "${CFG_SRC}/${dir}" ]] \
    && cp -r "${CFG_SRC}/${dir}" "${CFG_DST}/${dir}"
done

# picom lives under Configuration files/ directly (not a subdir)
if [[ -f "${CFG_SRC}/picom.conf" ]]; then
  mkdir -p "${CFG_DST}/picom"
  cp "${CFG_SRC}/picom.conf" "${CFG_DST}/picom/picom.conf"
fi

chown -R "${USERNAME}:${USERNAME}" "${CFG_DST}"

# Claude Code config lives under ~/.claude/, not ~/.config/
if [[ -d "${CFG_SRC}/claude" ]]; then
  CLAUDE_DST="/home/${USERNAME}/.claude"
  mkdir -p "${CLAUDE_DST}"
  cp "${CFG_SRC}/claude/settings.json"       "${CLAUDE_DST}/settings.json"
  cp "${CFG_SRC}/claude/settings.local.json" "${CLAUDE_DST}/settings.local.json" 2>/dev/null || true
  chown -R "${USERNAME}:${USERNAME}" "${CLAUDE_DST}"
  info "Claude Code config synced to ~/.claude/"
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

# ── Done ─────────────────────────────────────────────────────────
step "Chroot complete"
info "  Bootloader : /boot/limine.conf"
info "  Username   : ${USERNAME}"
info "  Hostname   : ${HOSTNAME_INPUT}"
info "  Dotfiles   : ${DOTS_DIR}"
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
  /root/install-chroot.sh

# ── Unmount ───────────────────────────────────────────────────────
step "Unmounting"
umount -R "${MOUNT}" 2>/dev/null || true
cryptsetup close cryptroot 2>/dev/null || true

echo ""
info "Done. Remove install media and reboot."
info "On first login, run:  nvim +Lazy +qa   to pull Neovim plugins."
