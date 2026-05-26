#!/usr/bin/env python3
"""
kconfig-gen: Generate a Linux kernel .config based on loaded modules and device specs.

Usage:
  python3 kconfig-gen.py [--output .config] [--base /boot/config-$(uname -r)]
"""

import os
import re
import sys
import struct
import argparse
import platform
import subprocess
from pathlib import Path
from collections import OrderedDict


# ---------------------------------------------------------------------------
# Hardware detection helpers
# ---------------------------------------------------------------------------

def read_file(path: str, default: str = "") -> str:
    try:
        return Path(path).read_text(errors="replace").strip()
    except OSError:
        return default


def read_lines(path: str) -> list[str]:
    try:
        return Path(path).read_text(errors="replace").splitlines()
    except OSError:
        return []


def run(cmd: list[str], default: str = "") -> str:
    try:
        return subprocess.check_output(cmd, stderr=subprocess.DEVNULL, text=True).strip()
    except Exception:
        return default


def pci_devices() -> list[dict]:
    """Return list of {vendor, device, class} dicts from sysfs."""
    devices = []
    base = Path("/sys/bus/pci/devices")
    if not base.exists():
        return devices
    for dev in base.iterdir():
        vendor = read_file(str(dev / "vendor")).lstrip("0x").lower().zfill(4)
        device = read_file(str(dev / "device")).lstrip("0x").lower().zfill(4)
        cls    = read_file(str(dev / "class")).lstrip("0x").lower()
        devices.append({"vendor": vendor, "device": device, "class": cls, "path": str(dev)})
    return devices


def usb_devices() -> list[dict]:
    """Return list of {idVendor, idProduct, bDeviceClass} dicts."""
    devices = []
    base = Path("/sys/bus/usb/devices")
    if not base.exists():
        return devices
    for dev in base.iterdir():
        vendor  = read_file(str(dev / "idVendor"))
        product = read_file(str(dev / "idProduct"))
        cls     = read_file(str(dev / "bDeviceClass"))
        if vendor:
            devices.append({"vendor": vendor, "product": product, "class": cls})
    return devices


def cpu_info() -> dict:
    info: dict[str, str] = {}
    for line in read_lines("/proc/cpuinfo"):
        if ":" in line:
            k, _, v = line.partition(":")
            k = k.strip().lower().replace(" ", "_")
            if k not in info:
                info[k] = v.strip()
    # count logical CPUs
    info["cpu_count"] = str(sum(1 for l in read_lines("/proc/cpuinfo") if l.startswith("processor")))
    return info


def mem_info() -> dict[str, int]:
    info: dict[str, int] = {}
    for line in read_lines("/proc/meminfo"):
        m = re.match(r"(\w+):\s+(\d+)", line)
        if m:
            info[m.group(1)] = int(m.group(2))  # kB
    return info


def dmi_info() -> dict[str, str]:
    base = Path("/sys/class/dmi/id")
    fields = ["sys_vendor", "product_name", "product_version", "board_vendor",
              "board_name", "chassis_type", "bios_vendor", "bios_version"]
    return {f: read_file(str(base / f)) for f in fields}


def loaded_modules() -> list[str]:
    mods = []
    for line in read_lines("/proc/modules"):
        parts = line.split()
        if parts:
            mods.append(parts[0])
    return mods


def block_devices() -> list[str]:
    base = Path("/sys/block")
    if not base.exists():
        return []
    return [d.name for d in base.iterdir()]


def net_devices() -> list[str]:
    base = Path("/sys/class/net")
    if not base.exists():
        return []
    return [d.name for d in base.iterdir()]


def kernel_cmdline() -> str:
    return read_file("/proc/cmdline")


def kernel_version() -> str:
    return platform.release()


# ---------------------------------------------------------------------------
# Module → Kconfig symbol mapping
# ---------------------------------------------------------------------------

# fmt: off
MODULE_TO_KCONFIG: dict[str, list[str]] = {
    # --- Filesystems ---
    "ext4":           ["CONFIG_EXT4_FS=y"],
    "ext3":           ["CONFIG_EXT3_FS=y"],
    "ext2":           ["CONFIG_EXT2_FS=y"],
    "btrfs":          ["CONFIG_BTRFS_FS=y"],
    "xfs":            ["CONFIG_XFS_FS=y"],
    "f2fs":           ["CONFIG_F2FS_FS=y"],
    "ntfs":           ["CONFIG_NTFS_FS=m"],
    "ntfs3":          ["CONFIG_NTFS3_FS=y"],
    "vfat":           ["CONFIG_VFAT_FS=y", "CONFIG_FAT_FS=y"],
    "exfat":          ["CONFIG_EXFAT_FS=y"],
    "iso9660":        ["CONFIG_ISO9660_FS=y"],
    "udf":            ["CONFIG_UDF_FS=m"],
    "nfs":            ["CONFIG_NFS_FS=m"],
    "nfsv4":          ["CONFIG_NFS_V4=m"],
    "cifs":           ["CONFIG_CIFS=m"],
    "fuse":           ["CONFIG_FUSE_FS=m"],
    "overlayfs":      ["CONFIG_OVERLAY_FS=y"],
    "tmpfs":          ["CONFIG_TMPFS=y"],
    "squashfs":       ["CONFIG_SQUASHFS=m"],
    "erofs":          ["CONFIG_EROFS_FS=m"],
    "jfs":            ["CONFIG_JFS_FS=m"],
    "reiserfs":       ["CONFIG_REISERFS_FS=m"],
    "cramfs":         ["CONFIG_CRAMFS=m"],
    "9p":             ["CONFIG_9P_FS=m"],
    "virtiofs":       ["CONFIG_VIRTIO_FS=m"],
    "zonefs":         ["CONFIG_ZONEFS_FS=m"],
    "bcachefs":       ["CONFIG_BCACHEFS_FS=m"],

    # --- Block layer ---
    "dm_mod":         ["CONFIG_BLK_DEV_DM=m"],
    "dm_crypt":       ["CONFIG_DM_CRYPT=m"],
    "dm_verity":      ["CONFIG_DM_VERITY=m"],
    "dm_integrity":   ["CONFIG_DM_INTEGRITY=m"],
    "dm_mirror":      ["CONFIG_DM_MIRROR=m"],
    "dm_raid":        ["CONFIG_DM_RAID=m"],
    "md_mod":         ["CONFIG_MD=y"],
    "raid0":          ["CONFIG_MD_RAID0=m"],
    "raid1":          ["CONFIG_MD_RAID1=m"],
    "raid456":        ["CONFIG_MD_RAID456=m"],
    "raid10":         ["CONFIG_MD_RAID10=m"],
    "loop":           ["CONFIG_BLK_DEV_LOOP=m"],
    "nbd":            ["CONFIG_BLK_DEV_NBD=m"],
    "zram":           ["CONFIG_ZRAM=m"],
    "bcache":         ["CONFIG_BCACHE=m"],
    "nvme":           ["CONFIG_BLK_DEV_NVME=m"],
    "nvme_core":      ["CONFIG_NVME_CORE=m"],
    "nvme_fabrics":   ["CONFIG_NVME_FABRICS=m"],
    "nvme_tcp":       ["CONFIG_NVME_TCP=m"],
    "nvme_rdma":      ["CONFIG_NVME_RDMA=m"],
    "nvme_fc":        ["CONFIG_NVME_FC=m"],
    "libata":         ["CONFIG_ATA=m"],
    "ahci":           ["CONFIG_SATA_AHCI=m"],
    "ata_piix":       ["CONFIG_ATA_PIIX=m"],
    "pata_acpi":      ["CONFIG_PATA_ACPI=m"],
    "sd_mod":         ["CONFIG_BLK_DEV_SD=y"],
    "sr_mod":         ["CONFIG_BLK_DEV_SR=m"],
    "scsi_mod":       ["CONFIG_SCSI=y"],
    "scsi_transport_sas": ["CONFIG_SCSI_SAS_LIBSAS=m"],
    "ufs":            ["CONFIG_SCSI_UFS=m"],
    "virtio_blk":     ["CONFIG_VIRTIO_BLK=m"],
    "virtio_scsi":    ["CONFIG_SCSI_VIRTIO=m"],
    "mmc_core":       ["CONFIG_MMC=m"],
    "sdhci":          ["CONFIG_MMC_SDHCI=m"],
    "sdhci_pci":      ["CONFIG_MMC_SDHCI_PCI=m"],
    "sdhci_acpi":     ["CONFIG_MMC_SDHCI_ACPI=m"],
    "mmc_block":      ["CONFIG_MMC_BLOCK=m"],
    "uas":            ["CONFIG_USB_UAS=m"],
    "usb_storage":    ["CONFIG_USB_STORAGE=m"],

    # --- Network drivers ---
    "e1000":          ["CONFIG_E1000=m"],
    "e1000e":         ["CONFIG_E1000E=m"],
    "igb":            ["CONFIG_IGB=m"],
    "ixgbe":          ["CONFIG_IXGBE=m"],
    "i40e":           ["CONFIG_I40E=m"],
    "ice":            ["CONFIG_ICE=m"],
    "r8169":          ["CONFIG_R8169=m"],
    "rtl8xxxu":       ["CONFIG_RTL8XXXU=m"],
    "rtl8192cu":      ["CONFIG_RTL8192CU=m"],
    "ath9k":          ["CONFIG_ATH9K=m"],
    "ath10k_pci":     ["CONFIG_ATH10K_PCI=m"],
    "ath10k_core":    ["CONFIG_ATH10K_CORE=m"],
    "ath11k":         ["CONFIG_ATH11K=m"],
    "ath11k_pci":     ["CONFIG_ATH11K_PCI=m"],
    "ath12k":         ["CONFIG_ATH12K=m"],
    "iwlwifi":        ["CONFIG_IWLWIFI=m"],
    "iwlmvm":         ["CONFIG_IWLMVM=m"],
    "iwldvm":         ["CONFIG_IWLDVM=m"],
    "mt7921e":        ["CONFIG_MT7921E=m"],
    "mt7921u":        ["CONFIG_MT7921U=m"],
    "mt7921s":        ["CONFIG_MT7921S=m"],
    "mt7922":         ["CONFIG_MT7922_COMMON=m"],
    "brcmfmac":       ["CONFIG_BRCMFMAC=m"],
    "brcmsmac":       ["CONFIG_BRCMSMAC=m"],
    "mwifiex_pcie":   ["CONFIG_MWIFIEX_PCIE=m"],
    "mwifiex":        ["CONFIG_MWIFIEX=m"],
    "rtw88_pci":      ["CONFIG_RTW88_PCI=m"],
    "rtw88_core":     ["CONFIG_RTW88_CORE=m"],
    "rtw89_pci":      ["CONFIG_RTW89_PCI=m"],
    "rtw89_core":     ["CONFIG_RTW89_CORE=m"],
    "virtio_net":     ["CONFIG_VIRTIO_NET=m"],
    "vmxnet3":        ["CONFIG_VMXNET3=m"],
    "tg3":            ["CONFIG_TIGON3=m"],
    "bnx2":           ["CONFIG_BNX2=m"],
    "be2net":         ["CONFIG_BE2NET=m"],
    "mlx4_en":        ["CONFIG_MLX4_EN=m"],
    "mlx5_core":      ["CONFIG_MLX5_CORE=m"],
    "8021q":          ["CONFIG_VLAN_8021Q=m"],
    "bonding":        ["CONFIG_BONDING=m"],
    "bridge":         ["CONFIG_BRIDGE=m"],
    "team":           ["CONFIG_NET_TEAM=m"],
    "macvlan":        ["CONFIG_MACVLAN=m"],
    "ipvlan":         ["CONFIG_IPVLAN=m"],
    "vxlan":          ["CONFIG_VXLAN=m"],
    "wireguard":      ["CONFIG_WIREGUARD=m"],
    "tun":            ["CONFIG_TUN=m"],
    "tap":            ["CONFIG_TUN=m"],

    # --- USB ---
    "usbcore":        ["CONFIG_USB=y"],
    "ehci_hcd":       ["CONFIG_USB_EHCI_HCD=y"],
    "xhci_hcd":       ["CONFIG_USB_XHCI_HCD=y"],
    "uhci_hcd":       ["CONFIG_USB_UHCI_HCD=m"],
    "ohci_hcd":       ["CONFIG_USB_OHCI_HCD=m"],
    "xhci_pci":       ["CONFIG_USB_XHCI_PCI=y"],
    "ehci_pci":       ["CONFIG_USB_EHCI_PCI=y"],
    "usb_common":     ["CONFIG_USB_COMMON=y"],
    "hid":            ["CONFIG_HID=m"],
    "hid_generic":    ["CONFIG_HID_GENERIC=m"],
    "usbhid":         ["CONFIG_USB_HID=m"],
    "btusb":          ["CONFIG_BT_HCIBTUSB=m"],
    "cdc_acm":        ["CONFIG_USB_ACM=m"],
    "cdc_ether":      ["CONFIG_USB_CDC_ETHER=m"],
    "cdc_ncm":        ["CONFIG_USB_CDC_NCM=m"],
    "rndis_host":     ["CONFIG_USB_NET_RNDIS_HOST=m"],
    "usb_wwan":       ["CONFIG_USB_WWAN=m"],
    "qmi_wwan":       ["CONFIG_USB_QMI_WWAN=m"],
    "sierra":         ["CONFIG_USB_SIERRA=m"],
    "option":         ["CONFIG_USB_SERIAL_OPTION=m"],
    "cp210x":         ["CONFIG_USB_SERIAL_CP210X=m"],
    "ch341":          ["CONFIG_USB_SERIAL_CH341=m"],
    "ftdi_sio":       ["CONFIG_USB_SERIAL_FTDI_SIO=m"],
    "pl2303":         ["CONFIG_USB_SERIAL_PL2303=m"],

    # --- Input ---
    "input_core":     ["CONFIG_INPUT=y"],
    "evdev":          ["CONFIG_INPUT_EVDEV=y"],
    "keyboard":       ["CONFIG_KEYBOARD_ATKBD=y"],
    "mousedev":       ["CONFIG_INPUT_MOUSEDEV=m"],
    "atkbd":          ["CONFIG_KEYBOARD_ATKBD=y"],
    "psmouse":        ["CONFIG_MOUSE_PS2=y"],
    "i8042":          ["CONFIG_SERIO_I8042=y"],
    "serio":          ["CONFIG_SERIO=y"],
    "libps2":         ["CONFIG_SERIO=y"],
    "hid_multitouch": ["CONFIG_HID_MULTITOUCH=m"],
    "wacom":          ["CONFIG_HID_WACOM=m"],
    "joydev":         ["CONFIG_INPUT_JOYDEV=m"],
    "gameport":       ["CONFIG_GAMEPORT=m"],
    "ff_memless":     ["CONFIG_INPUT_FF_MEMLESS=m"],
    "xpad":           ["CONFIG_JOYSTICK_XPAD=m"],

    # --- GPU / DRM ---
    "drm":            ["CONFIG_DRM=m"],
    "drm_kms_helper": ["CONFIG_DRM_KMS_HELPER=m"],
    "i915":           ["CONFIG_DRM_I915=m"],
    "amdgpu":         ["CONFIG_DRM_AMDGPU=m"],
    "radeon":         ["CONFIG_DRM_RADEON=m"],
    "nouveau":        ["CONFIG_DRM_NOUVEAU=m"],
    "ast":            ["CONFIG_DRM_AST=m"],
    "bochs":          ["CONFIG_DRM_BOCHS=m"],
    "cirrus":         ["CONFIG_DRM_CIRRUS_QEMU=m"],
    "qxl":            ["CONFIG_DRM_QXL=m"],
    "virtio_gpu":     ["CONFIG_DRM_VIRTIO_GPU=m"],
    "vboxvideo":      ["CONFIG_DRM_VBOXVIDEO=m"],
    "vmwgfx":         ["CONFIG_DRM_VMWGFX=m"],
    "mgag200":        ["CONFIG_DRM_MGA=m"],
    "fbdev":          ["CONFIG_FB=y"],
    "fb":             ["CONFIG_FB=y"],
    "vesafb":         ["CONFIG_FB_VESA=y"],
    "efifb":          ["CONFIG_FB_EFI=y"],
    "simplefb":       ["CONFIG_FB_SIMPLE=y"],

    # --- Sound ---
    "snd":            ["CONFIG_SOUND=y"],
    "soundcore":      ["CONFIG_SOUND=y"],
    "snd_pcm":        ["CONFIG_SND_PCM=m"],
    "snd_timer":      ["CONFIG_SND_TIMER=m"],
    "snd_hda_intel":  ["CONFIG_SND_HDA_INTEL=m"],
    "snd_hda_core":   ["CONFIG_SND_HDA_CORE=m"],
    "snd_hda_codec":  ["CONFIG_SND_HDA_CODEC=m"],
    "snd_hda_codec_realtek": ["CONFIG_SND_HDA_CODEC_REALTEK=m"],
    "snd_hda_codec_hdmi": ["CONFIG_SND_HDA_CODEC_HDMI=m"],
    "snd_sof":        ["CONFIG_SND_SOF=m"],
    "snd_sof_pci":    ["CONFIG_SND_SOF_PCI=m"],
    "snd_sof_intel_hda_common": ["CONFIG_SND_SOF_INTEL_HDA_COMMON=m"],
    "snd_usb_audio":  ["CONFIG_SND_USB_AUDIO=m"],
    "snd_usbmidi_lib": ["CONFIG_SND_USB_MIDI_LIB=m"],
    "snd_seq":        ["CONFIG_SND_SEQUENCER=m"],
    "snd_rawmidi":    ["CONFIG_SND_RAWMIDI=m"],
    "snd_jack":       ["CONFIG_SND_JACK=y"],
    "snd_compress":   ["CONFIG_SND_COMPRESS_OFFLOAD=m"],
    "snd_pcsp":       ["CONFIG_SND_PCSP=m"],

    # --- Crypto ---
    "aesni_intel":    ["CONFIG_CRYPTO_AES_NI_INTEL=m"],
    "crc32c_intel":   ["CONFIG_CRYPTO_CRC32C_INTEL=m"],
    "crc32_pclmul":   ["CONFIG_CRYPTO_CRC32_PCLMUL=m"],
    "ghash_clmulni_intel": ["CONFIG_CRYPTO_GHASH_CLMUL_NI_INTEL=m"],
    "sha256_ssse3":   ["CONFIG_CRYPTO_SHA256_SSSE3=m"],
    "sha512_ssse3":   ["CONFIG_CRYPTO_SHA512_SSSE3=m"],
    "sha1_ssse3":     ["CONFIG_CRYPTO_SHA1_SSSE3=m"],
    "poly1305_x86_64": ["CONFIG_CRYPTO_POLY1305_X86_64=m"],
    "chacha20_x86_64": ["CONFIG_CRYPTO_CHACHA20_X86_64=m"],
    "algif_hash":     ["CONFIG_CRYPTO_USER_API_HASH=m"],
    "algif_skcipher": ["CONFIG_CRYPTO_USER_API_SKCIPHER=m"],
    "algif_aead":     ["CONFIG_CRYPTO_USER_API_AEAD=m"],
    "hmac":           ["CONFIG_CRYPTO_HMAC=y"],
    "drbg":           ["CONFIG_CRYPTO_DRBG=m"],
    "jitterentropy_rng": ["CONFIG_CRYPTO_JITTERENTROPY=m"],

    # --- Virtualization ---
    "kvm":            ["CONFIG_KVM=m"],
    "kvm_intel":      ["CONFIG_KVM_INTEL=m"],
    "kvm_amd":        ["CONFIG_KVM_AMD=m"],
    "vhost_net":      ["CONFIG_VHOST_NET=m"],
    "vhost":          ["CONFIG_VHOST=m"],
    "virtio":         ["CONFIG_VIRTIO=m"],
    "virtio_pci":     ["CONFIG_VIRTIO_PCI=m"],
    "virtio_mmio":    ["CONFIG_VIRTIO_MMIO=m"],
    "virtio_ring":    ["CONFIG_VIRTIO_RING=m"],
    "9pnet_virtio":   ["CONFIG_9P_FS=m", "CONFIG_NET_9P=m", "CONFIG_NET_9P_VIRTIO=m"],
    "hyperv":         ["CONFIG_HYPERV=m"],
    "hv_netvsc":      ["CONFIG_HYPERV_NET=m"],
    "hv_storvsc":     ["CONFIG_SCSI_STORVSC=m"],
    "vmw_vmci":       ["CONFIG_VMWARE_VMCI=m"],
    "vmwgfx":         ["CONFIG_DRM_VMWGFX=m"],
    "vboxguest":      ["CONFIG_VBOXGUEST=m"],
    "xen_blkfront":   ["CONFIG_XEN_BLKDEV_FRONTEND=m"],
    "xen_netfront":   ["CONFIG_XEN_NETDEV_FRONTEND=m"],

    # --- Power management ---
    "acpi":           ["CONFIG_ACPI=y"],
    "battery":        ["CONFIG_ACPI_BATTERY=m"],
    "ac":             ["CONFIG_ACPI_AC=m"],
    "button":         ["CONFIG_ACPI_BUTTON=m"],
    "video":          ["CONFIG_ACPI_VIDEO=m"],
    "thermal":        ["CONFIG_THERMAL=y"],
    "intel_powerclamp": ["CONFIG_INTEL_POWERCLAMP=m"],
    "intel_rapl":     ["CONFIG_INTEL_RAPL=m"],
    "intel_rapl_msr": ["CONFIG_INTEL_RAPL_MSR=m"],
    "intel_idle":     ["CONFIG_INTEL_IDLE=y"],
    "cpufreq_performance": ["CONFIG_CPU_FREQ_GOV_PERFORMANCE=y"],
    "cpufreq_powersave": ["CONFIG_CPU_FREQ_GOV_POWERSAVE=m"],
    "cpufreq_ondemand": ["CONFIG_CPU_FREQ_GOV_ONDEMAND=m"],
    "acpi_cpufreq":   ["CONFIG_X86_ACPI_CPUFREQ=m"],
    "intel_pstate":   ["CONFIG_X86_INTEL_PSTATE=y"],
    "processor":      ["CONFIG_ACPI_PROCESSOR=m"],

    # --- Platform / miscellaneous ---
    "spi_nor":        ["CONFIG_MTD_SPI_NOR=m"],
    "i2c_core":       ["CONFIG_I2C=m"],
    "i2c_i801":       ["CONFIG_I2C_I801=m"],
    "i2c_piix4":      ["CONFIG_I2C_PIIX4=m"],
    "i2c_hid":        ["CONFIG_I2C_HID=m"],
    "i2c_hid_acpi":   ["CONFIG_I2C_HID_ACPI=m"],
    "spi_pxa2xx_platform": ["CONFIG_SPI_PXA2XX=m"],
    "spi_pxa2xx_pci": ["CONFIG_SPI_PXA2XX_PCI=m"],
    "intel_lpss":     ["CONFIG_MFD_INTEL_LPSS=m"],
    "intel_lpss_pci": ["CONFIG_MFD_INTEL_LPSS_PCI=m"],
    "intel_lpss_acpi": ["CONFIG_MFD_INTEL_LPSS_ACPI=m"],
    "pinctrl_intel":  ["CONFIG_PINCTRL_INTEL=m"],
    "pinctrl_tigerlake": ["CONFIG_PINCTRL_TIGERLAKE=m"],
    "pinctrl_alderlake": ["CONFIG_PINCTRL_ALDERLAKE=m"],
    "pinctrl_cannonlake": ["CONFIG_PINCTRL_CANNONLAKE=m"],
    "thinkpad_acpi":  ["CONFIG_THINKPAD_ACPI=m"],
    "asus_wmi":       ["CONFIG_ASUS_WMI=m"],
    "dell_wmi":       ["CONFIG_DELL_WMI=m"],
    "hp_wmi":         ["CONFIG_HP_WMI=m"],
    "msr":            ["CONFIG_X86_MSR=m"],
    "cpuid":          ["CONFIG_X86_CPUID=m"],
    "pcspkr":         ["CONFIG_INPUT_PCSPKR=m"],
    "lp":             ["CONFIG_PRINTER=m"],
    "rtc_cmos":       ["CONFIG_RTC_DRV_CMOS=y"],
    "w83627hf":       ["CONFIG_SENSORS_W83627HF=m"],
    "coretemp":       ["CONFIG_SENSORS_CORETEMP=m"],
    "k10temp":        ["CONFIG_SENSORS_K10TEMP=m"],
    "nct6775":        ["CONFIG_SENSORS_NCT6775=m"],
    "fuse":           ["CONFIG_FUSE_FS=m"],
    "ip_tables":      ["CONFIG_IP_NF_IPTABLES=m", "CONFIG_NETFILTER=y"],
    "ip6_tables":     ["CONFIG_IP6_NF_IPTABLES=m"],
    "nf_conntrack":   ["CONFIG_NF_CONNTRACK=m"],
    "nf_nat":         ["CONFIG_NF_NAT=m"],
    "xt_state":       ["CONFIG_NETFILTER_XT_MATCH_STATE=m"],
    "xt_conntrack":   ["CONFIG_NETFILTER_XT_MATCH_CONNTRACK=m"],
    "ipt_MASQUERADE": ["CONFIG_IP_NF_TARGET_MASQUERADE=m"],
    "nft_compat":     ["CONFIG_NFT_COMPAT=m"],
    "nf_tables":      ["CONFIG_NF_TABLES=m"],
    "cfg80211":       ["CONFIG_CFG80211=m"],
    "mac80211":       ["CONFIG_MAC80211=m"],
    "bluetooth":      ["CONFIG_BT=m"],
    "bluetooth_6lowpan": ["CONFIG_BT_6LOWPAN=m"],
    "rfkill":         ["CONFIG_RFKILL=m"],
    "ledtrig_heartbeat": ["CONFIG_LEDS_TRIGGER_HEARTBEAT=m"],
    "leds_class":     ["CONFIG_NEW_LEDS=y", "CONFIG_LEDS_CLASS=y"],
    "backlight":      ["CONFIG_BACKLIGHT_CLASS_DEVICE=m"],
    "mei":            ["CONFIG_INTEL_MEI=m"],
    "mei_me":         ["CONFIG_INTEL_MEI_ME=m"],
    "mei_hdcp":       ["CONFIG_INTEL_MEI_HDCP=m"],
    "mei_pxp":        ["CONFIG_INTEL_MEI_PXP=m"],
    "cros_ec":        ["CONFIG_CROS_EC=m"],
    "cros_ec_lpcs":   ["CONFIG_CROS_EC_LPC=m"],
    "drm_panel_orientation_quirks": ["CONFIG_DRM_PANEL_ORIENTATION_QUIRKS=y"],
    "iommu_v2":       ["CONFIG_AMD_IOMMU_V2=m"],
    "amd_iommu_v2":   ["CONFIG_AMD_IOMMU_V2=m"],
    "vfio":           ["CONFIG_VFIO=m"],
    "vfio_pci":       ["CONFIG_VFIO_PCI=m"],
    "iommufd":        ["CONFIG_IOMMUFD=m"],
}
# fmt: on


# ---------------------------------------------------------------------------
# PCI class → Kconfig mapping
# ---------------------------------------------------------------------------

# PCI class codes (top 2 hex bytes of the 6-digit class field)
PCI_CLASS_TO_KCONFIG: dict[str, list[str]] = {
    "0200": ["CONFIG_ETHERNET=y", "CONFIG_NET=y"],            # Ethernet
    "0280": ["CONFIG_WLAN=y", "CONFIG_CFG80211=m"],           # Wireless
    "0300": ["CONFIG_DRM=m", "CONFIG_FB=y"],                  # VGA compatible
    "0302": ["CONFIG_DRM=m"],                                 # 3D / other display
    "0401": ["CONFIG_SOUND=y"],                               # Multimedia audio
    "0403": ["CONFIG_SOUND=y", "CONFIG_SND=y"],               # Audio device
    "0600": [],                                               # Host bridge (no module)
    "0601": [],                                               # ISA bridge
    "0604": [],                                               # PCI–PCI bridge
    "0700": ["CONFIG_SERIAL_8250=y"],                         # Serial
    "0c00": ["CONFIG_FIREWIRE=m"],                            # FireWire
    "0c03": ["CONFIG_USB_XHCI_HCD=y", "CONFIG_USB=y"],        # USB3
    "0c04": ["CONFIG_INFINIBAND=m"],                          # Fibre Channel
    "0c05": ["CONFIG_I2C=m"],                                 # SMBus
    "0c07": ["CONFIG_BT=m"],                                  # Bluetooth
    "0c08": ["CONFIG_PCIE_RCAR_HOST=m"],                      # PCI Express
    "0c80": ["CONFIG_WLAN=y"],                                # Wireless (alt)
    "1000": ["CONFIG_SCSI=y"],                                # SCSI
    "0101": ["CONFIG_ATA=m"],                                 # IDE
    "0106": ["CONFIG_SATA_AHCI=m"],                           # SATA AHCI
    "0108": ["CONFIG_BLK_DEV_NVME=m"],                        # NVMe
    "0d40": ["CONFIG_WLAN=y"],                                # Wireless network
}


# ---------------------------------------------------------------------------
# CPU feature → Kconfig
# ---------------------------------------------------------------------------

CPU_FEATURE_TO_KCONFIG: dict[str, list[str]] = {
    "aes":        ["CONFIG_CRYPTO_AES_NI_INTEL=m"],
    "avx":        ["CONFIG_AS_AVX=y"],
    "avx2":       ["CONFIG_AS_AVX2=y"],
    "avx512f":    ["CONFIG_AS_AVX512=y"],
    "hypervisor": ["CONFIG_HYPERVISOR_GUEST=y", "CONFIG_PARAVIRT=y"],
    "vmx":        ["CONFIG_KVM_INTEL=m"],
    "svm":        ["CONFIG_KVM_AMD=m"],
    "ht":         ["CONFIG_HT=y"],
    "pae":        ["CONFIG_X86_PAE=y"],
    "nx":         ["CONFIG_X86_64=y"],
    "lm":         ["CONFIG_X86_64=y"],
    "smx":        ["CONFIG_INTEL_TXT=y"],
    "rdrand":     ["CONFIG_ARCH_RANDOM=y"],
    "rdseed":     ["CONFIG_ARCH_RANDOM=y"],
    "tsc":        ["CONFIG_X86_TSC=y"],
    "constant_tsc": ["CONFIG_X86_TSC=y"],
    "ida":        ["CONFIG_X86_ACPI_CPUFREQ=m"],
    "est":        ["CONFIG_X86_ACPI_CPUFREQ=m"],
    "tm2":        ["CONFIG_X86_ACPI_CPUFREQ=m"],
    "pebs":       ["CONFIG_PERF_EVENTS_INTEL_UNCORE=m"],
    "bts":        ["CONFIG_PERF_EVENTS=y"],
    "pt":         ["CONFIG_INTEL_PT=y"],
    "cqm_mbm_total": ["CONFIG_QOS_RESOURCE=y"],
    "mpx":        ["CONFIG_X86_INTEL_MPX=y"],
    "intel_pt":   ["CONFIG_INTEL_PT=y"],
}


# ---------------------------------------------------------------------------
# Config builder
# ---------------------------------------------------------------------------

class KconfigBuilder:
    def __init__(self, base_config: dict[str, str] | None = None):
        self.config: dict[str, str] = OrderedDict()
        self.comments: dict[str, str] = {}
        if base_config:
            self.config.update(base_config)

    def set(self, key: str, value: str, comment: str = ""):
        # Don't downgrade y→m
        existing = self.config.get(key)
        if existing == "y" and value == "m":
            return
        self.config[key] = value
        if comment:
            self.comments[key] = comment

    def apply_list(self, entries: list[str], comment: str = ""):
        for entry in entries:
            if "=" in entry:
                k, _, v = entry.partition("=")
                self.set(k, v, comment)

    def not_set(self, key: str):
        if key not in self.config:
            self.config[key] = "n"

    def render(self) -> str:
        lines = [
            "#",
            "# Generated by kconfig-gen.py",
            f"# Kernel: {kernel_version()}",
            "#",
            "",
        ]
        for key, val in self.config.items():
            cmt = self.comments.get(key)
            if cmt:
                lines.append(f"# {cmt}")
            if val in ("y", "m", "n", "2"):
                lines.append(f"{key}={val}")
            elif val.startswith('"') or val.lstrip("-").isdigit():
                lines.append(f"{key}={val}")
            else:
                lines.append(f"# {key} is not set" if val == "n" else f"{key}={val}")
        return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Base / architecture config
# ---------------------------------------------------------------------------

def arch_config(builder: KconfigBuilder, cpu: dict):
    arch = platform.machine()

    if arch in ("x86_64", "AMD64"):
        builder.set("CONFIG_X86_64", "y", "Architecture")
        builder.set("CONFIG_X86", "y")
        builder.set("CONFIG_64BIT", "y")
        builder.set("CONFIG_X86_GENERIC", "y")
        builder.set("CONFIG_PGTABLE_LEVELS", "5")

        # Detect micro-arch from model name
        model = cpu.get("model_name", "").lower()
        if "intel" in model:
            builder.set("CONFIG_CPU_SUP_INTEL", "y")
            if "core" in model or "xeon" in model:
                if any(x in model for x in ("skylake", "kaby", "coffee", "whiskey",
                                             "comet", "ice lake", "tiger", "alder",
                                             "raptor", "meteor")):
                    builder.set("CONFIG_MSKYLAKE", "y")
                elif "broadwell" in model:
                    builder.set("CONFIG_MBROADWELL", "y")
                elif "haswell" in model:
                    builder.set("CONFIG_MHASWELL", "y")
                elif "ivy" in model:
                    builder.set("CONFIG_MIVYBRIDGE", "y")
                elif "sandy" in model:
                    builder.set("CONFIG_MSANDYBRIDGE", "y")
                elif "nehalem" in model or "westmere" in model:
                    builder.set("CONFIG_MNEHALEM", "y")
                else:
                    builder.set("CONFIG_MCORE2", "y")
            else:
                builder.set("CONFIG_MPSC", "y")
            builder.set("CONFIG_INTEL_IDLE", "y")
            builder.set("CONFIG_X86_INTEL_PSTATE", "y")
            builder.set("CONFIG_ENERGY_MODEL", "y")
        elif "amd" in model or "ryzen" in model or "epyc" in model:
            builder.set("CONFIG_CPU_SUP_AMD", "y")
            if "zen" in model or "ryzen" in model or "epyc" in model:
                builder.set("CONFIG_MZEN3", "y")
            else:
                builder.set("CONFIG_MK8", "y")
            builder.set("CONFIG_X86_ACPI_CPUFREQ", "m")

        builder.set("CONFIG_SMP", "y")
        builder.set("CONFIG_MAXSMP", "y")
        builder.set("CONFIG_X86_LOCAL_APIC", "y")
        builder.set("CONFIG_X86_IO_APIC", "y")
        builder.set("CONFIG_X86_X2APIC", "y")
        builder.set("CONFIG_X86_TSC", "y")
        builder.set("CONFIG_X86_CMPXCHG64", "y")
        builder.set("CONFIG_X86_CMOV", "y")
        builder.set("CONFIG_RWSEM_XCHGADD_ALGORITHM", "y")
        builder.set("CONFIG_GENERIC_CALIBRATE_DELAY", "y")
        builder.set("CONFIG_ARCH_RANDOM", "y")
        builder.set("CONFIG_PHYSICAL_START", "0x1000000")
        builder.set("CONFIG_PHYSICAL_ALIGN", "0x200000")

    elif arch.startswith("aarch64") or arch == "arm64":
        builder.set("CONFIG_ARM64", "y")
        builder.set("CONFIG_64BIT", "y")

    # Common
    builder.set("CONFIG_MMU", "y")
    builder.set("CONFIG_GENERIC_ISA_DMA", "y")
    builder.set("CONFIG_ZONE_DMA", "y")
    builder.set("CONFIG_ZONE_DMA32", "y")


def memory_config(builder: KconfigBuilder, mem: dict[str, int]):
    total_mb = mem.get("MemTotal", 0) // 1024

    if total_mb > 0:
        builder.set("CONFIG_HIGHMEM64G" if total_mb > 4096 else "CONFIG_HIGHMEM", "y",
                    f"RAM detected: ~{total_mb} MB")

    if total_mb > 65536:
        builder.set("CONFIG_X86_5LEVEL", "y", "Large memory: 5-level paging beneficial")

    builder.set("CONFIG_MEMORY_HOTPLUG", "y" if total_mb > 8192 else "n")
    builder.set("CONFIG_NUMA", "y" if total_mb > 16384 else "n")
    builder.set("CONFIG_SPARSEMEM", "y")
    builder.set("CONFIG_SPARSEMEM_VMEMMAP", "y")
    builder.set("CONFIG_COMPACTION", "y")
    builder.set("CONFIG_MIGRATION", "y")
    builder.set("CONFIG_KSM", "y")
    builder.set("CONFIG_TRANSPARENT_HUGEPAGE", "y")
    builder.set("CONFIG_ZSWAP", "y")
    builder.set("CONFIG_ZSMALLOC", "m")
    builder.set("CONFIG_ZRAM", "m")


def cpu_features_config(builder: KconfigBuilder, cpu: dict):
    flags = set(cpu.get("flags", "").split())

    for flag, kconfigs in CPU_FEATURE_TO_KCONFIG.items():
        if flag in flags:
            builder.apply_list(kconfigs, f"CPU flag: {flag}")

    ncpus = int(cpu.get("cpu_count", "1"))
    if ncpus > 1:
        builder.set("CONFIG_SMP", "y", f"{ncpus} logical CPUs detected")
        builder.set("CONFIG_NR_CPUS", str(max(ncpus * 2, 8)))

    if "hypervisor" in flags:
        builder.set("CONFIG_HYPERVISOR_GUEST", "y", "Running inside VM")
        builder.set("CONFIG_PARAVIRT", "y")
        builder.set("CONFIG_PARAVIRT_SPINLOCKS", "y")
        builder.set("CONFIG_KVM_GUEST", "y")


def pci_config(builder: KconfigBuilder, devices: list[dict]):
    seen_classes: set[str] = set()
    for dev in devices:
        cls6 = dev["class"]  # e.g. "060400"
        cls4 = cls6[:4]       # "0604"
        if cls4 not in seen_classes:
            seen_classes.add(cls4)
            if cls4 in PCI_CLASS_TO_KCONFIG:
                builder.apply_list(PCI_CLASS_TO_KCONFIG[cls4],
                                   f"PCI class {cls4}")

    # Always need PCI core
    builder.set("CONFIG_PCI", "y")
    builder.set("CONFIG_PCI_MSI", "y")
    builder.set("CONFIG_PCIEPORTBUS", "y")
    builder.set("CONFIG_PCIE_PME", "y")
    builder.set("CONFIG_PCI_IOV", "y")
    builder.set("CONFIG_HOTPLUG_PCI", "y")
    builder.set("CONFIG_HOTPLUG_PCI_PCIE", "y")


def modules_config(builder: KconfigBuilder, modules: list[str]):
    for mod in modules:
        kconfigs = MODULE_TO_KCONFIG.get(mod)
        if kconfigs:
            builder.apply_list(kconfigs, f"module: {mod}")


def block_config(builder: KconfigBuilder, devices: list[str]):
    has_nvme  = any(d.startswith("nvme")    for d in devices)
    has_mmc   = any(d.startswith("mmcblk")  for d in devices)
    has_sata  = any(d.startswith(("sd", "hd")) for d in devices)
    has_vd    = any(d.startswith("vd")      for d in devices)
    has_zram  = any(d.startswith("zram")    for d in devices)

    if has_nvme:
        builder.set("CONFIG_BLK_DEV_NVME", "m", "NVMe block device detected")
        builder.set("CONFIG_NVME_CORE", "m")
    if has_mmc:
        builder.set("CONFIG_MMC", "m", "MMC/SD block device detected")
        builder.set("CONFIG_MMC_BLOCK", "m")
        builder.set("CONFIG_MMC_SDHCI", "m")
        builder.set("CONFIG_MMC_SDHCI_PCI", "m")
    if has_sata:
        builder.set("CONFIG_ATA", "m", "ATA/SATA block device detected")
        builder.set("CONFIG_SATA_AHCI", "m")
        builder.set("CONFIG_BLK_DEV_SD", "y")
    if has_vd:
        builder.set("CONFIG_VIRTIO_BLK", "m", "VirtIO block device detected")
    if has_zram:
        builder.set("CONFIG_ZRAM", "m", "ZRAM device detected")

    builder.set("CONFIG_BLOCK", "y")
    builder.set("CONFIG_BLK_DEV_BSGLIB", "y")
    builder.set("CONFIG_BLK_WBT", "y")
    builder.set("CONFIG_MQ_IOSCHED_DEADLINE", "y")
    builder.set("CONFIG_MQ_IOSCHED_KYBER", "m")
    builder.set("CONFIG_IOSCHED_BFQ", "y")
    builder.set("CONFIG_BLK_CGROUP", "y")


def net_config(builder: KconfigBuilder, ifaces: list[str]):
    has_wlan = any(n.startswith(("wlan", "wlp", "wlx")) for n in ifaces)
    has_eth  = any(n.startswith(("eth", "enp", "ens", "eno", "enx")) for n in ifaces)
    has_virt = any(n in ("virbr0", "docker0", "lxcbr0") for n in ifaces)

    builder.set("CONFIG_NET", "y")
    builder.set("CONFIG_INET", "y")
    builder.set("CONFIG_IPV6", "m")
    builder.set("CONFIG_NETFILTER", "y")
    builder.set("CONFIG_UNIX", "y")

    if has_wlan:
        builder.set("CONFIG_CFG80211", "m", "Wireless interface detected")
        builder.set("CONFIG_MAC80211", "m")
        builder.set("CONFIG_WLAN", "y")
        builder.set("CONFIG_RFKILL", "m")
    if has_virt:
        builder.set("CONFIG_TUN", "m", "Virtual network interface detected")
        builder.set("CONFIG_BRIDGE", "m")
        builder.set("CONFIG_MACVLAN", "m")
        builder.set("CONFIG_VXLAN", "m")

    builder.set("CONFIG_PACKET", "y")
    builder.set("CONFIG_PACKET_DIAG", "m")
    builder.set("CONFIG_UNIX_DIAG", "m")
    builder.set("CONFIG_INET_DIAG", "m")
    builder.set("CONFIG_TCP_CONG_CUBIC", "y")
    builder.set("CONFIG_TCP_CONG_BBR", "m")
    builder.set("CONFIG_DEFAULT_TCP_CONG", '"cubic"')
    builder.set("CONFIG_MULTIPATH_TCP", "m")


def firmware_config(builder: KconfigBuilder, dmi: dict):
    cmdline = kernel_cmdline()
    has_efi = Path("/sys/firmware/efi").exists()
    chassis = dmi.get("chassis_type", "")

    if has_efi:
        builder.set("CONFIG_EFI", "y", "EFI firmware detected")
        builder.set("CONFIG_EFI_STUB", "y")
        builder.set("CONFIG_EFI_VARS", "m")
        builder.set("CONFIG_EFI_MIXED", "y")
        builder.set("CONFIG_FB_EFI", "y")

    builder.set("CONFIG_ACPI", "y")
    builder.set("CONFIG_ACPI_BATTERY", "m")
    builder.set("CONFIG_ACPI_AC", "m")
    builder.set("CONFIG_ACPI_BUTTON", "m")
    builder.set("CONFIG_ACPI_VIDEO", "m")
    builder.set("CONFIG_ACPI_FAN", "m")
    builder.set("CONFIG_ACPI_PROCESSOR", "m")
    builder.set("CONFIG_ACPI_CPPC_LIB", "y")
    builder.set("CONFIG_ACPI_HOTPLUG_CPU", "y")

    # Laptop heuristic
    is_laptop = chassis in ("8", "9", "10", "14") or any(
        k in dmi.get("product_name", "").lower()
        for k in ("laptop", "notebook", "thinkpad", "xps", "elitebook",
                  "probook", "zenbook", "vivobook", "ideapad", "latitude",
                  "inspiron", "pavilion", "spectre", "envy")
    )
    if is_laptop:
        builder.set("CONFIG_ACPI_WMI", "m", "Laptop chassis detected")
        builder.set("CONFIG_BACKLIGHT_CLASS_DEVICE", "m")
        builder.set("CONFIG_BACKLIGHT_GENERIC", "m")
        builder.set("CONFIG_BATTERY", "m")
        builder.set("CONFIG_SENSORS_APPLESMC", "m")

    if "iommu" in cmdline or Path("/sys/kernel/iommu_groups").exists():
        builder.set("CONFIG_INTEL_IOMMU", "y", "IOMMU in use")
        builder.set("CONFIG_AMD_IOMMU", "y")
        builder.set("CONFIG_IOMMU_API", "y")
        builder.set("CONFIG_IOMMU_SUPPORT", "y")


def security_config(builder: KconfigBuilder):
    builder.set("CONFIG_SECURITY", "y")
    builder.set("CONFIG_SECURITY_SELINUX", "y")
    builder.set("CONFIG_SECURITY_APPARMOR", "y")
    builder.set("CONFIG_DEFAULT_SECURITY_APPARMOR", "y")
    builder.set("CONFIG_SECCOMP", "y")
    builder.set("CONFIG_SECCOMP_FILTER", "y")
    builder.set("CONFIG_HARDENED_USERCOPY", "y")
    builder.set("CONFIG_FORTIFY_SOURCE", "y")
    builder.set("CONFIG_STACKPROTECTOR", "y")
    builder.set("CONFIG_STACKPROTECTOR_STRONG", "y")
    builder.set("CONFIG_STRICT_KERNEL_RWX", "y")
    builder.set("CONFIG_STRICT_MODULE_RWX", "y")
    builder.set("CONFIG_RANDOMIZE_BASE", "y")
    builder.set("CONFIG_RANDOMIZE_MEMORY", "y")
    builder.set("CONFIG_RETPOLINE", "y")
    builder.set("CONFIG_PAGE_TABLE_ISOLATION", "y")
    builder.set("CONFIG_CPU_MITIGATIONS", "y")
    builder.set("CONFIG_LOCK_DOWN_KERNEL_FORCE_NONE", "y")
    builder.set("CONFIG_MODULE_SIG", "y")
    builder.set("CONFIG_MODULE_SIG_ALL", "y")
    builder.set("CONFIG_MODULE_SIG_SHA512", "y")


def misc_always_on(builder: KconfigBuilder):
    """Things that are nearly always needed."""
    builder.set("CONFIG_MODULES", "y")
    builder.set("CONFIG_MODULE_UNLOAD", "y")
    builder.set("CONFIG_MODVERSIONS", "y")
    builder.set("CONFIG_MODULE_SRCVERSION_ALL", "y")
    builder.set("CONFIG_SYSFS", "y")
    builder.set("CONFIG_PROC_FS", "y")
    builder.set("CONFIG_DEVTMPFS", "y")
    builder.set("CONFIG_DEVTMPFS_MOUNT", "y")
    builder.set("CONFIG_DEVPTS_MULTIPLE_INSTANCES", "y")
    builder.set("CONFIG_TMPFS", "y")
    builder.set("CONFIG_TMPFS_POSIX_ACL", "y")
    builder.set("CONFIG_UNIX98_PTYS", "y")
    builder.set("CONFIG_VT", "y")
    builder.set("CONFIG_CONSOLE_TRANSLATIONS", "y")
    builder.set("CONFIG_VT_CONSOLE", "y")
    builder.set("CONFIG_HW_CONSOLE", "y")
    builder.set("CONFIG_TTY", "y")
    builder.set("CONFIG_SERIAL_EARLYCON", "y")
    builder.set("CONFIG_PRINTK", "y")
    builder.set("CONFIG_BUG", "y")
    builder.set("CONFIG_ELF_CORE", "y")
    builder.set("CONFIG_BINFMT_ELF", "y")
    builder.set("CONFIG_BINFMT_SCRIPT", "y")
    builder.set("CONFIG_BINFMT_MISC", "m")
    builder.set("CONFIG_COREDUMP", "y")
    builder.set("CONFIG_FUTEX", "y")
    builder.set("CONFIG_EPOLL", "y")
    builder.set("CONFIG_INOTIFY_USER", "y")
    builder.set("CONFIG_FANOTIFY", "y")
    builder.set("CONFIG_POSIX_TIMERS", "y")
    builder.set("CONFIG_TIMERFD", "y")
    builder.set("CONFIG_EVENTFD", "y")
    builder.set("CONFIG_SIGNALFD", "y")
    builder.set("CONFIG_AIO", "y")
    builder.set("CONFIG_IO_URING", "y")
    builder.set("CONFIG_MEMFD_CREATE", "y")
    builder.set("CONFIG_CGROUPS", "y")
    builder.set("CONFIG_CGROUP_SCHED", "y")
    builder.set("CONFIG_CGROUP_CPUACCT", "y")
    builder.set("CONFIG_MEMCG", "y")
    builder.set("CONFIG_BLK_CGROUP", "y")
    builder.set("CONFIG_NAMESPACES", "y")
    builder.set("CONFIG_UTS_NS", "y")
    builder.set("CONFIG_IPC_NS", "y")
    builder.set("CONFIG_PID_NS", "y")
    builder.set("CONFIG_NET_NS", "y")
    builder.set("CONFIG_USER_NS", "y")
    builder.set("CONFIG_SCHED_AUTOGROUP", "y")
    builder.set("CONFIG_POSIX_MQUEUE", "y")
    builder.set("CONFIG_KEYS", "y")
    builder.set("CONFIG_AUDIT", "y")
    builder.set("CONFIG_PERF_EVENTS", "y")
    builder.set("CONFIG_PROFILING", "y")
    builder.set("CONFIG_KPROBES", "y")
    builder.set("CONFIG_UPROBES", "y")
    builder.set("CONFIG_TRACEPOINTS", "y")
    builder.set("CONFIG_FTRACE", "y")
    builder.set("CONFIG_DYNAMIC_FTRACE", "y")
    builder.set("CONFIG_FUNCTION_TRACER", "y")
    builder.set("CONFIG_SCHED_TRACER", "y")
    builder.set("CONFIG_DEBUG_FS", "y")
    builder.set("CONFIG_MAGIC_SYSRQ", "y")
    builder.set("CONFIG_RTC_CLASS", "y")
    builder.set("CONFIG_RTC_DRV_CMOS", "y")
    builder.set("CONFIG_DMIID", "y")
    builder.set("CONFIG_DMI_SCAN_MACHINE_NON_EFI_FALLBACK", "y")
    builder.set("CONFIG_FIRMWARE_MEMMAP", "y")
    builder.set("CONFIG_FW_LOADER", "y")
    builder.set("CONFIG_FW_LOADER_USER_HELPER", "y")
    builder.set("CONFIG_EXTRA_FIRMWARE", '""')
    builder.set("CONFIG_CRYPTO", "y")
    builder.set("CONFIG_CRYPTO_AES", "y")
    builder.set("CONFIG_CRYPTO_SHA256", "y")
    builder.set("CONFIG_CRYPTO_SHA512", "y")
    builder.set("CONFIG_CRYPTO_CHACHA20POLY1305", "m")
    builder.set("CONFIG_CRYPTO_USER_API", "m")
    builder.set("CONFIG_CRYPTO_USER_API_HASH", "m")
    builder.set("CONFIG_CRYPTO_USER_API_SKCIPHER", "m")
    builder.set("CONFIG_LIBCRC32C", "m")
    builder.set("CONFIG_CRC32", "y")
    builder.set("CONFIG_CRC32C", "m")
    builder.set("CONFIG_ZLIB_INFLATE", "y")
    builder.set("CONFIG_ZLIB_DEFLATE", "m")
    builder.set("CONFIG_LZ4_COMPRESS", "m")
    builder.set("CONFIG_ZSTD_COMPRESS", "m")
    builder.set("CONFIG_ZSTD_DECOMPRESS", "m")


# ---------------------------------------------------------------------------
# Load an existing .config as reference
# ---------------------------------------------------------------------------

def load_config(path: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in read_lines(path):
        line = line.strip()
        if line.startswith("# CONFIG_") and "is not set" in line:
            key = line.split()[1]
            result[key] = "n"
        elif line.startswith("CONFIG_"):
            k, _, v = line.partition("=")
            result[k.strip()] = v.strip()
    return result


# ---------------------------------------------------------------------------
# Summary printer
# ---------------------------------------------------------------------------

def print_summary(cpu: dict, mem: dict[str, int], dmi: dict,
                  modules: list[str], pci: list[dict], usb: list[dict],
                  blocks: list[str], nets: list[str]):
    print("=" * 60)
    print("Hardware summary")
    print("=" * 60)
    print(f"  Kernel    : {kernel_version()}")
    print(f"  CPU       : {cpu.get('model_name', 'unknown')}")
    print(f"  CPUs      : {cpu.get('cpu_count', '?')} logical")
    print(f"  RAM       : {mem.get('MemTotal', 0) // 1024} MB")
    print(f"  Vendor    : {dmi.get('sys_vendor', '?')} {dmi.get('product_name', '')}")
    print(f"  PCI devs  : {len(pci)}")
    print(f"  USB devs  : {len(usb)}")
    print(f"  Block devs: {', '.join(blocks) or 'none'}")
    print(f"  Net ifaces: {', '.join(nets) or 'none'}")
    print(f"  Modules   : {len(modules)} loaded")
    print("=" * 60)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Generate a Linux kernel .config from loaded modules + hardware")
    parser.add_argument("-o", "--output", default=".config",
                        help="Output file (default: .config)")
    parser.add_argument("--base", default="",
                        help="Base .config to start from (e.g. /boot/config-$(uname -r))")
    parser.add_argument("--auto-base", action="store_true",
                        help="Auto-detect running kernel config in /boot")
    parser.add_argument("--no-security", action="store_true",
                        help="Skip hardening/security config section")
    parser.add_argument("--summary-only", action="store_true",
                        help="Only print hardware summary, don't write .config")
    args = parser.parse_args()

    # -- Gather hardware info ------------------------------------------------
    cpu     = cpu_info()
    mem     = mem_info()
    dmi     = dmi_info()
    modules = loaded_modules()
    pci     = pci_devices()
    usb     = usb_devices()
    blocks  = block_devices()
    nets    = net_devices()

    print_summary(cpu, mem, dmi, modules, pci, usb, blocks, nets)

    if args.summary_only:
        return 0

    # -- Base config ---------------------------------------------------------
    base: dict[str, str] = {}
    base_path = args.base

    if not base_path and args.auto_base:
        candidate = f"/boot/config-{kernel_version()}"
        if Path(candidate).exists():
            base_path = candidate
        else:
            for p in sorted(Path("/boot").glob("config-*")):
                base_path = str(p)
                break

    if base_path and Path(base_path).exists():
        print(f"\nLoading base config: {base_path}")
        base = load_config(base_path)
        print(f"  {len(base)} symbols loaded")

    # -- Build ---------------------------------------------------------------
    builder = KconfigBuilder(base)

    print("\nDetecting hardware and applying config...")
    misc_always_on(builder)
    arch_config(builder, cpu)
    memory_config(builder, mem)
    cpu_features_config(builder, cpu)
    pci_config(builder, pci)
    modules_config(builder, modules)
    block_config(builder, blocks)
    net_config(builder, nets)
    firmware_config(builder, dmi)

    if not args.no_security:
        security_config(builder)

    # -- Write ---------------------------------------------------------------
    out = args.output
    output = builder.render()
    Path(out).write_text(output)
    print(f"\nWrote {len(builder.config)} config symbols to: {out}")

    # Stats
    n_y = sum(1 for v in builder.config.values() if v == "y")
    n_m = sum(1 for v in builder.config.values() if v == "m")
    n_n = sum(1 for v in builder.config.values() if v == "n")
    print(f"  y={n_y}  m={n_m}  n={n_n}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
