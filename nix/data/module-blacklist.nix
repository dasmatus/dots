# Kernel modules refused outright, ported from secureblue's
# `/usr/lib/modprobe.d/secureblue.conf` (`reference/secureblue-modprobe.conf`
# in this project's SDD notes). Grouped and commented exactly as upstream
# groups them — the sole change is dropping the small handful of
# `install speakup* /bin/false` lines upstream itself keeps commented out
# ("kernel debugging modules for blind users... don't uncomment unless
# it's confirmed [they] are used exclusively for kernel development"), and
# de-duplicating four module names upstream lists twice (zl10036, zl10039,
# zl10353, zd1301_demod each appear once in the DVB-frontends block and
# once in the tuners/dvb-usb-v2 block).
#
# This is a substantial, structurally-preserved copy of secureblue's own
# list, not an independent selection — see REUSE.toml, where this path
# carries secureblue's Apache-2.0 license and copyright rather than this
# repo's default AGPL-3.0-only.
#
# Consumed by nix/modules/system/hardening.nix, which renders every entry
# into `install <mod> /bin/false` (boot.extraModprobeConfig) rather than
# NixOS's `boot.blacklistedKernelModules` — see that file's comment for why
# the stronger form was chosen to match secureblue rather than silently
# weaken it. Bluetooth (`bluetooth`, `btusb`, `bluetooth_6lowpan`) is in
# this list deliberately: nix/modules/system/form-factor.nix now disables
# `hardware.bluetooth.enable` outright, and this closes the module path a
# `modprobe bluetooth` could still take around that.
#
# NOT applied verbatim: hardening.nix filters the 9p family (9p, 9pnet,
# 9pnet_fd, 9pnet_rdma, 9pnet_usbg, 9pnet_virtio, 9pnet_xen) back out of
# this list before rendering it, because blocking those modules breaks
# `pkgs.testers.runNixOSTest`'s virtio-9p store share — see hardening.nix's
# own comment for how that was found (a kernel panic in `session-boot`
# before the test driver's shell ever came up). `joydev` is filtered back
# out the same way, because this machine deliberately runs Steam and
# blacklisting the joystick layer under it kills gamepad support outright
# — see hardening.nix's comment beside that filter. This file stays the
# faithful, unfiltered copy of secureblue's list on purpose, so both
# divergences are visible as filters at the consumption site instead of a
# silent gap in what looks like a straight port.
[
  # unused network protocols
  "dccp"
  "xt_dccp"
  "sctp"
  "xt_sctp"
  "sctp_diag"
  "rds"
  "rds_rdma"
  "rds_tcp"
  "tipc"
  "tipc_diag"
  "n-hdlc"
  "hdlcdrv"
  "ax25"
  "netrom"
  "x25"
  "rose"
  "decnet"
  "econet"
  "af_802154"
  "ipx"
  "appletalk"
  "psnap"
  "p8023"
  "p8022"
  "atm"
  "usbatm"
  "xusbatm"
  "pppoatm"
  "atmtcp"
  "mctp-serial"
  "mctp-usb"
  "mctp-i3c"
  "batman-adv"

  # firewire and thunderbolt
  "firewire-core"
  "firewire_core"
  "firewire-ohci"
  "firewire_ohci"
  "firewire_sbp2"
  "firewire-sbp2"
  "firewire-net"
  # Kept deliberately, unlike joydev above: Thunderbolt DMA is a genuine
  # attack surface (PCIe devices behind the controller can DMA into memory
  # before the OS gets to authorize them), and this machine already runs
  # USBGuard with a device allowlist, so refusing an unvetted DMA-capable
  # bus outright is consistent with that posture rather than fighting it.
  # The cost: a Thunderbolt 3/USB4 dock or an eGPU stops enumerating.
  "thunderbolt"
  "thunderbolt_net"
  "ohci1394"
  "sbp2"
  "dv1394"
  "raw1394"
  "video1394"
  # https://github.com/torvalds/linux/blob/master/drivers/firewire/nosy.c
  "nosy"
  # https://github.com/torvalds/linux/blob/master/drivers/media/firewire/firedtv-dvb.c
  "firedtv"

  # unused filesystems
  "cramfs"
  "freevxfs"
  "jffs2"
  "hfs"
  "hfsplus"
  # Safe only because nix/system/iso.nix (via flake/lib.nix's mkIso) does
  # NOT import nix/modules/system/hardening.nix — the LiveISO's own root is
  # a squashfs store, so this list reaching the ISO closure would brick it.
  # If a future refactor ever routes hardening.nix (or this file) into the
  # ISO's module list, this entry needs an explicit carve-out first.
  "squashfs"
  "udf"
  "cifs"
  "cifs_md4"
  "nfs"
  "nfsv3"
  "nfsv4"
  "rpcsec_gss_krb5"
  "auth_rpcgss"
  "nfs_acl"
  "nfsd"
  "nfs_layout_flexfiles"
  "nfs_layout_nfsv41_files"
  "nfs_localio"
  # https://github.com/torvalds/linux/blob/master/fs/nfs_common/grace.c
  "grace"
  # https://github.com/torvalds/linux/blob/master/fs/lockd/svc.c
  "lockd"
  "ksmbd"
  "gfs2"
  "reiserfs"
  "kafs"
  "orangefs"
  "9p"
  "9pnet"
  "9pnet_fd"
  "9pnet_rdma"
  "9pnet_usbg"
  "9pnet_virtio"
  "9pnet_xen"
  "adfs"
  "affs"
  "afs"
  "befs"
  "ceph"
  "coda"
  "ecryptfs"
  "jfs"
  "minix"
  "nilfs2"
  "ocfs2"
  "romfs"
  "ubifs"
  "zonefs"
  "sysv"
  "ufs"
  # https://documentation.suse.com/sle-ha/12-SP5/html/SLE-HA-all/cha-ha-storage-dlm.html
  "dlm"
  # https://en.wikipedia.org/wiki/OCFS2
  "ocfs2_dlm"
  "ocfs2_dlmfs"
  "ocfs2_nodemanager"
  "ocfs2_stackglue"
  "ocfs2_stack_o2cb"
  "ocfs2_stack_user"

  # disable GNSS
  "gnss"
  "gnss-mtk"
  "gnss-serial"
  "gnss-sirf"
  "gnss-usb"
  "gnss-ubx"

  # https://en.wikipedia.org/wiki/Bluetooth#History_of_security_concerns
  "bluetooth"
  "btusb"

  # block loading ath_pci
  "ath_pci"

  # X86 android tablet support
  # https://github.com/torvalds/linux/tree/master/drivers/platform/x86/x86-android-tablets
  "x86-android-tablets"

  # block loading cdrom
  "cdrom"
  "sr_mod"

  # dirtyfrag mitigation: https://github.com/V4bel/dirtyfrag#mitigation
  # RxRPC network protocol: https://www.kernel.org/doc/html/latest/networking/rxrpc.html
  "rxrpc"

  # esp4 and esp6 provide support for Encapsulating Security Payload, part of IPSec.
  "esp4"
  "esp4_offload"
  "esp6"
  "esp6_offload"

  # xfrm, another part of IPSec involved in related exploits
  "nft_xfrm"
  "xfrm4_tunnel"
  "xfrm6_tunnel"
  "xfrm_algo"
  "xfrm_interface"
  "xfrm_ipcomp"
  "xfrm_iptfs"
  "xfrm_user"

  # disable remaining ipsec modules
  "ah4"
  "ah6"
  "ipcomp"
  "ipcomp6"
  "af_key"

  # disable l2tp (depends on ipsec)
  "l2tp_core"
  "l2tp_debugfs"
  "l2tp_eth"
  "l2tp_ip"
  "l2tp_ip6"
  "l2tp_netlink"
  "l2tp_ppp"
  "xt_l2tp"

  # disable Sun RPC: https://en.wikipedia.org/wiki/Sun_RPC
  "sunrpc"

  # legacy interfaces
  # https://en.wikipedia.org/wiki/Parallel_port
  "parport"
  "parport_cs"
  "parport_pc"
  "parport_serial"
  "pps_parport"
  "i2c-parport"
  # https://github.com/torvalds/linux/blob/master/drivers/char/ppdev.c
  "ppdev"
  # https://github.com/torvalds/linux/blob/master/drivers/char/lp.c
  "lp"

  # https://en.wikipedia.org/wiki/Game_port
  "gameport"
  # https://en.wikipedia.org/wiki/Floppy_disk
  "floppy"

  # kernel debugging / development modules
  # https://linux.die.net/man/8/mce-inject
  "mce-inject"
  # https://github.com/torvalds/linux/blob/master/mm/hwpoison-inject.c
  "hwpoison-inject"
  # https://github.com/torvalds/linux/blob/master/drivers/pci/pcie/aer_inject.c
  "aer_inject"
  # https://github.com/torvalds/linux/blob/master/drivers/scsi/scsi_debug.c
  "scsi_debug"
  # https://github.com/torvalds/linux/blob/master/drivers/usb/serial/usb_debug.c
  "usb_debug"
  # https://github.com/torvalds/linux/blob/master/kernel/trace/ring_buffer_benchmark.c
  "ring_buffer_benchmark"
  # https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/vkms/vkms_drv.c
  "vkms"
  # diagnostic module for vsock: https://man7.org/linux/man-pages/man7/vsock.7.html
  "vsock_diag"
  # diagnostic module for xdp: https://github.com/torvalds/linux/blob/master/net/xdp/xsk_diag.c
  "xsk_diag"
  # https://docs.kernel.org/admin-guide/media/visl.html
  # https://github.com/torvalds/linux/tree/master/drivers/media/test-drivers/visl
  "visl"
  # https://github.com/torvalds/linux/blob/master/drivers/media/test-drivers/vim2m.c
  "vim2m"
  # https://docs.kernel.org/admin-guide/media/vimc.html
  # https://github.com/torvalds/linux/tree/master/drivers/media/test-drivers/vimc
  "vimc"
  # disable vivid
  "vivid"
  # https://github.com/torvalds/linux/blob/master/drivers/usb/gadget/udc/dummy_hcd.c
  "dummy_hcd"
  # https://manpages.ubuntu.com/manpages/bionic/man4/nandsim.4freebsd.html
  # https://github.com/torvalds/linux/blob/master/drivers/mtd/nand/raw/nandsim.c
  "nandsim"
  # https://github.com/torvalds/linux/blob/master/drivers/mtd/devices/mtdram.c
  "mtdram"

  # kernel debugging modules for blind users
  # Don't uncomment unless it's confirmed that these modules are used exclusively for kernel development

  # kernel message logging over UDP
  # https://www.kernel.org/doc/Documentation/networking/netconsole.txt
  "netconsole"

  # automotive/industrial linux
  # https://www.ti.com/lit/ds/symlink/dp83tg720s-q1.pdf
  "dp83tg720"
  # https://github.com/torvalds/linux/blob/master/drivers/net/phy/marvell-88q2xxx.c
  "marvell-88q2xxx"
  # https://github.com/torvalds/linux/blob/master/drivers/net/phy/marvell-88x2222.c
  "marvell-88x2222"
  # https://www.microchip.com/en-us/products/high-speed-networking-and-video/ethernet/single-pair-ethernet
  "microchip_t1s"
  # car backup cameras
  # https://github.com/torvalds/linux/blob/master/drivers/media/i2c/max9271.c
  "max9271"
  # https://en.wikipedia.org/wiki/CAN_bus
  # https://en.wikipedia.org/wiki/Vehicle_bus
  "can"
  "can327"
  "can-bcm"
  "can-gw"
  "can-isotp"
  "can-j1939"
  "can-raw"
  "ctucanfd"
  "ctucanfd_pci"
  "ifi_canfd"
  "m_can"
  "m_can_pci"
  "slcan"
  "vcan"
  "vxcan"
  # https://github.com/torvalds/linux/blob/master/drivers/net/can/usb/peak_usb/pcan_usb_core.c
  "peak_usb"
  # https://github.com/torvalds/linux/blob/master/drivers/net/can/peak_canfd/peak_pciefd_main.c
  "peak_pciefd"
  # https://github.com/torvalds/linux/tree/master/drivers/net/can/usb/kvaser_usb
  "kvaser_usb"
  # https://github.com/torvalds/linux/blob/master/drivers/net/can/usb/gs_usb.c
  "gs_usb"
  # https://en.wikipedia.org/wiki/6LoWPAN
  "6lowpan"
  "bluetooth_6lowpan"
  "ieee802154_6lowpan"

  # RDMA https://wiki.debian.org/RDMA
  # https://github.com/torvalds/linux/blob/master/net/smc/smc.h
  "smc"
  "smc_diag"
  "erdma"
  "ionic_rdma"
  "irdma"
  "nvme-rdma"
  "nvmet-rdma"
  "ocrdma"
  "rdma_cm"
  "rdma_rxe"
  "rdma_ucm"
  "rdmavt"
  "rpcrdma"
  "vmw_pvrdma"

  # GPIB
  # https://en.wikipedia.org/wiki/GPIB
  # https://github.com/torvalds/linux/blob/master/drivers/gpib/common/gpib_os.c
  "gpib_common"
  # https://github.com/torvalds/linux/blob/master/drivers/gpib/agilent_82350b/agilent_82350b.c
  "agilent_82350b"
  # https://github.com/torvalds/linux/blob/master/drivers/gpib/agilent_82357a/agilent_82357a.c
  "agilent_82357a"
  # https://github.com/torvalds/linux/blob/master/drivers/gpib/cb7210/cb7210.c
  "cb7210"
  # https://github.com/torvalds/linux/blob/master/drivers/gpib/cec/cec_gpib.c
  "cec_gpib"
  # https://github.com/torvalds/linux/blob/master/drivers/gpib/ines/ines_gpib.c
  "ines_gpib"
  # https://github.com/torvalds/linux/blob/master/drivers/gpib/lpvo_usb_gpib/lpvo_usb_gpib.c
  "lpvo_usb_gpib"
  # https://github.com/torvalds/linux/blob/master/drivers/gpib/nec7210/nec7210.c
  "nec7210"
  # https://github.com/torvalds/linux/blob/master/drivers/gpib/ni_usb/ni_usb_gpib.c
  "ni_usb_gpib"
  # # https://github.com/torvalds/linux/blob/master/drivers/gpib/tms9914/tms9914.c
  "tms9914"
  # https://github.com/torvalds/linux/tree/master/drivers/gpib/tnt4882
  "tnt4882"

  # DVB and TV receivers
  # https://www.kernel.org/doc/html/v4.9/media/uapi/dvb/intro.html
  # https://wiki.archlinux.org/title/DVB-T
  "dvb-as102"
  "dvb-bt8xx"
  # https://github.com/torvalds/linux/blob/master/drivers/media/pci/bt8xx/dst_ca.c
  "dst_ca"
  # https://github.com/torvalds/linux/blob/master/drivers/media/pci/bt8xx/dst.c
  "dst"
  "dvb-core"
  "dvb-pll"
  "dvb-ttusb-budget"
  "dvb-usb"
  "dvb-usb-a800"
  "dvb-usb-af9005"
  "dvb-usb-af9005-remote"
  "dvb-usb-af9015"
  "dvb-usb-af9035"
  "dvb-usb-anysee"
  "dvb-usb-au6610"
  "dvb-usb-az6007"
  "dvb-usb-az6027"
  "dvb-usb-ce6230"
  "dvb-usb-cinergyT2"
  "dvb-usb-cxusb"
  "dvb-usb-dib0700"
  "dvb-usb-dibusb-common"
  "dvb-usb-dibusb-mb"
  "dvb-usb-dibusb-mc"
  "dvb-usb-dibusb-mc-common"
  "dvb-usb-digitv"
  "dvb-usb-dtt200u"
  "dvb-usb-dtv5100"
  "dvb-usb-dvbsky"
  "dvb-usb-dw2102"
  "dvb-usb-ec168"
  "dvb-usb-gl861"
  "dvb-usb-gp8psk"
  "dvb-usb-lmedm04"
  "dvb-usb-m920x"
  "dvb-usb-mxl111sf"
  "dvb-usb-nova-t-usb2"
  "dvb-usb-opera"
  "dvb-usb-pctv452e"
  "dvb-usb-rtl28xxu"
  "dvb-usb-technisat-usb2"
  "dvb-usb-ttusb2"
  "dvb-usb-umt-010"
  "dvb_usb_v2"
  "dvb-usb-vp702x"
  "dvb-usb-vp7045"
  # https://www.kernel.org/doc/Documentation/media/dvb-drivers/ttusb-dec.rst
  "ttusb_dec"
  "ttusbdecfe"
  # https://github.com/torvalds/linux/tree/master/drivers/media/mmc/siano
  # https://docs.kernel.org/admin-guide/media/siano-cardlist.html
  "smsusb"
  "smsdvb"
  "smsmdtv"
  "smssdio"
  # https://github.com/torvalds/linux/tree/master/drivers/media/common/b2c2
  "b2c2-flexcop"
  "b2c2-flexcop-pci"
  "b2c2-flexcop-usb"
  # https://github.com/torvalds/linux/tree/master/drivers/media/usb/au0828
  "au0828"
  # https://github.com/torvalds/linux/blob/master/drivers/media/pci/saa7146/mxb.c
  "mxb"
  # https://www.linuxtv.org/wiki/index.php/NXP_SAA716x#Saa7164_IC_chip_information
  "saa7164"
  # https://www.linuxtv.org/wiki/index.php/Radio_Data_System_(RDS)
  "saa6588"
  # https://github.com/torvalds/linux/blob/master/drivers/media/pci/smipcie/smipcie-main.c
  "smipcie"
  # https://github.com/torvalds/linux/blob/master/drivers/media/pci/pluto2/pluto2.c
  "pluto2"
  # https://github.com/torvalds/linux/blob/master/drivers/media/pci/ngene/ngene-dvb.c
  "ngene"
  # https://github.com/torvalds/linux/blob/master/drivers/media/pci/mantis/mantis_dvb.c
  # https://github.com/torvalds/linux/blob/master/drivers/media/pci/mantis/hopper_cards.c
  "mantis"
  "mantis_core"
  "hopper"
  # https://github.com/torvalds/linux/blob/master/include/uapi/linux/ivtv.h
  # https://www.kernel.org/doc/html/v4.8/media/v4l-drivers/ivtv.html
  "ivtv"
  "ivtvfb"
  # https://github.com/torvalds/linux/tree/master/drivers/media/dvb-frontends
  "a8293"
  "af9013"
  "af9033"
  "as102_fe"
  "ascot2e"
  "atbm8830"
  "au8522_common"
  "au8522_decoder"
  "au8522_dig"
  "bcm3510"
  "cx22700"
  "cx22702"
  "cx24110"
  "cx24113"
  "cx24116"
  "cx24117"
  "cx24120"
  "cx24123"
  "cxd2099"
  "cxd2820r"
  "cxd2841er"
  "cxd2880-spi"
  "dib0070"
  "dib0090"
  "dib3000mb"
  "dib3000mc"
  "dib7000m"
  "dib7000p"
  "dib8000"
  "dibx000_common"
  "drx39xyj"
  "drxd"
  "drxk"
  "ds3000"
  "ec100"
  "gp8psk-fe"
  "helene"
  "horus3a"
  "isl6405"
  "isl6421"
  "isl6423"
  "itd1000"
  "ix2505v"
  "l64781"
  "lg2160"
  "lgdt3305"
  "lgdt3306a"
  "lgdt330x"
  "lgs8gxx"
  "lnbh25"
  "lnbp21"
  "lnbp22"
  "m88ds3103"
  "m88rs2000"
  "mb86a16"
  "mb86a20s"
  "mn88472"
  "mn88473"
  "mt312"
  "mt352"
  "mxl5xx"
  "mxl692"
  "nxt200x"
  "nxt6000"
  "or51132"
  "or51211"
  "rtl2830"
  "rtl2832"
  "s5h1409"
  "s5h1411"
  "s5h1420"
  "s921"
  "si2165"
  "si2168"
  "si21xx"
  "sp2"
  "sp887x"
  "stb0899"
  "stb6000"
  "stb6100"
  "stv0288"
  "stv0297"
  "stv0299"
  "stv0367"
  "stv0900"
  "stv090x"
  "stv0910"
  "stv6110"
  "stv6110x"
  "stv6111"
  "tc90522"
  "tda10021"
  "tda10023"
  "tda10048"
  "tda1004x"
  "tda10071"
  "tda10086"
  "tda18271c2dd"
  "tda665x"
  "tda8083"
  "tda8261"
  "tda826x"
  "ts2020"
  "tua6100"
  "ves1820"
  "ves1x93"
  "zd1301_demod"
  "zl10036"
  "zl10039"
  "zl10353"
  # https://github.com/torvalds/linux/tree/master/drivers/media/tuners
  "e4000"
  "fc0011"
  "fc0012"
  "fc0013"
  "fc2580"
  "it913x"
  "m88rs6000t"
  "max2165"
  "mc44s803"
  "mt2060"
  "mt2063"
  "mt20xx"
  "mt2131"
  "mt2266"
  "mxl301rf"
  "mxl5005s"
  "mxl5007t"
  "qm1d1b0004"
  "qm1d1c0042"
  "qt1010"
  "r820t"
  "si2157"
  "tda18212"
  "tda18218"
  "tda18250"
  "tda18271"
  "tda827x"
  "tda8290"
  "tda9887"
  "tea5761"
  "tea5767"
  "tua9001"
  "tuner"
  "tuner-simple"
  "tuner-types"
  "xc2028"
  "xc4000"
  "xc5000"
  # https://github.com/torvalds/linux/tree/master/drivers/media/usb/dvb-usb-v2
  "mxl111sf-demod"
  "mxl111sf-tuner"
  "zd1301"
  # https://docs.kernel.org/admin-guide/media/saa7134.html
  "saa7134"
  "saa7134-alsa"
  "saa7134-dvb"
  "saa7134-empress"
  "saa7134-go7007"
  # https://github.com/torvalds/linux/blob/master/drivers/media/usb/cx231xx/cx231xx.h
  "cx231xx"
  "cx231xx-alsa"
  "cx231xx-dvb"
  # https://github.com/torvalds/linux/blob/master/drivers/media/pci/cx88/cx88.h
  # https://github.com/torvalds/linux/blob/master/drivers/media/pci/cx88/cx88-input.c
  "cx88-alsa"
  "cx88-blackbird"
  "cx88-dvb"
  "cx88-vp3054-i2c"
  "cx88xx"
  "cx8800"
  "cx8802"
  # https://www.kernel.org/doc/html/v4.9/media/v4l-drivers/em28xx-cardlist.html
  "em28xx"
  "em28xx-alsa"
  "em28xx-dvb"
  "em28xx-rc"
  "em28xx-v4l"
  # https://www.kernelconfig.io/CONFIG_DVB_NETUP_UNIDVB
  "netup-unidvb"
  # https://linuxtv.org/wiki/index.php/Bttv#Associated_bttv_driver_modules
  "bttv"
  "bt819"
  "bt856"
  "bt866"
  "bt878"
  # https://wiki.mythtv.org/wiki/Snd-bt87x
  "snd-bt87x"
  # https://github.com/torvalds/linux/blob/master/drivers/media/usb/hdpvr/hdpvr.h
  # https://www.hauppauge.com/pages/products/data_hdpvr.html
  "hdpvr"
  # https://www.kernel.org/doc/html/v4.10/media/v4l-drivers/pvrusb2.html
  "pvrusb2"
  # https://www.linuxtv.org/wiki/index.php/Philips_SAA7146
  # https://github.com/torvalds/linux/blob/master/drivers/media/pci/saa7146/hexium_orion.c
  "saa7146"
  "saa7146_vv"
  "hexium_gemini"
  "hexium_orion"
  # http://www.szmjd.com/Attachments/product/201501/54c5e68c78140.pdf
  "go7007"
  "go7007-loader"
  "go7007-usb"
  # https://github.com/torvalds/linux/blob/master/drivers/media/pci/pt1/pt1.c
  # https://github.com/torvalds/linux/blob/master/drivers/media/pci/pt3/pt3.c
  "earth-pt1"
  "earth-pt3"
  # https://satline.tv/knowledge-base/digital-devices-octopus-twin-ci/
  # https://github.com/torvalds/linux/blob/master/drivers/media/pci/ddbridge/ddbridge-ci.c
  "ddbridge"
  "ddbridge-dummy-fe"
  # https://linuxtv.org/wiki/index.php/Conexant_CX23885/7/8
  # https://github.com/torvalds/linux/blob/master/drivers/media/pci/cx23885/cx23885.h
  # https://github.com/torvalds/linux/blob/master/drivers/media/pci/cx23885/altera-ci.c
  "cx23885"
  "altera-ci"
  # https://linuxtv.org/wiki/index.php/Cx18_devices_(cx23418)e
  "cx18"
  "cx18-alsa"
  # https://github.com/torvalds/linux/blob/master/drivers/media/pci/ttpci/budget-core.c
  "budget"
  "budget-av"
  "budget-ci"
  "budget-core"

  # joystick drivers
  # https://github.com/torvalds/linux/tree/master/drivers/input/joystick
  # https://github.com/torvalds/linux/blob/master/drivers/input/joystick/a3d.c
  "a3d"
  # https://github.com/torvalds/linux/blob/master/drivers/input/joystick/adc-joystick.c
  "adc-joystick"
  # https://github.com/torvalds/linux/blob/master/drivers/input/joystick/adi.c
  "adi"
  # https://github.com/torvalds/linux/blob/master/drivers/input/joystick/analog.c
  "analog"
  # https://github.com/torvalds/linux/blob/master/drivers/input/joystick/cobra.c
  "cobra"
  # https://github.com/torvalds/linux/blob/master/drivers/input/joystick/db9.c
  "db9"
  # https://github.com/torvalds/linux/blob/master/drivers/input/joystick/gamecon.c
  "gamecon"
  # https://github.com/torvalds/linux/blob/master/drivers/input/joystick/gf2k.c
  "gf2k"
  # https://github.com/torvalds/linux/blob/master/drivers/input/joystick/grip.c
  "grip"
  # https://github.com/torvalds/linux/blob/master/drivers/input/joystick/grip_mp.c
  "grip_mp"
  # https://github.com/torvalds/linux/blob/master/drivers/input/joystick/guillemot.c
  "guillemot"
  # https://github.com/torvalds/linux/tree/master/drivers/input/joystick/iforce
  "iforce"
  "iforce-serio"
  "iforce-usb"
  # https://github.com/torvalds/linux/blob/master/drivers/input/joystick/interact.c
  "interact"
  # https://docs.kernel.org/input/joydev/joystick.html
  # https://github.com/torvalds/linux/blob/master/drivers/input/joydev.c
  "joydev"
  # https://github.com/torvalds/linux/blob/master/drivers/input/joystick/joydump.c
  "joydump"
  # https://github.com/torvalds/linux/blob/master/drivers/input/joystick/magellan.c
  "magellan"
  # https://github.com/torvalds/linux/blob/master/drivers/input/joystick/psxpad-spi.c
  "psxpad-spi"
  # https://github.com/torvalds/linux/blob/master/drivers/input/joystick/pxrc.c
  # https://github.com/torvalds/linux/blob/master/drivers/hid/hid-pxrc.c
  "pxrc"
  "hid-pxrc"
  # https://github.com/torvalds/linux/blob/master/drivers/input/joystick/qwiic-joystick.c
  "qwiic-joystick"
  # https://github.com/torvalds/linux/blob/master/drivers/input/joystick/sidewinder.c
  "sidewinder"
  # https://github.com/torvalds/linux/blob/master/drivers/input/joystick/spaceball.c
  "spaceball"
  # https://github.com/torvalds/linux/blob/master/drivers/input/joystick/spaceorb.c
  "spaceorb"
  # https://github.com/torvalds/linux/blob/master/drivers/input/joystick/stinger.c
  "stinger"
  # https://github.com/torvalds/linux/blob/master/drivers/input/joystick/tmdc.c
  "tmdc"
  # https://github.com/torvalds/linux/blob/master/drivers/usb/misc/trancevibrator.c
  "trancedriver"
  # https://github.com/torvalds/linux/blob/master/drivers/input/joystick/turbografx.c
  "turbografx"
  # https://github.com/torvalds/linux/blob/master/drivers/input/joystick/twidjoy.c
  "twidjoy"
  # https://github.com/torvalds/linux/blob/master/drivers/input/joystick/walkera0701.c
  "walkera0701"
  # https://github.com/torvalds/linux/blob/master/drivers/input/joystick/warrior.c
  "warrior"
  # https://github.com/torvalds/linux/blob/master/drivers/input/joystick/zhenhua.c
  "zhenhua"

  # Remote controls
  "rc-adstech-dvb-t-pci"
  "rc-alink-dtu-m"
  "rc-anysee"
  "rc-apac-viewcomp"
  "rc-astrometa-t2hybrid"
  "rc-asus-pc39"
  "rc-asus-ps3-100"
  "rc-ati-tv-wonder-hd-600"
  "rc-ati-x10"
  "rc-avermedia"
  "rc-avermedia-a16d"
  "rc-avermedia-cardbus"
  "rc-avermedia-dvbt"
  "rc-avermedia-m135a"
  "rc-avermedia-m733a-rm-k6"
  "rc-avermedia-rm-ks"
  "rc-avertv-303"
  "rc-azurewave-ad-tu700"
  "rc-beelink-gs1"
  "rc-beelink-mxiii"
  "rc-behold"
  "rc-behold-columbus"
  "rc-budget-ci-old"
  "rc-cinergy"
  "rc-cinergy-1400"
  "rc-ct-90405"
  "rc-d680-dmb"
  "rc-delock-61959"
  "rc-dib0700-nec"
  "rc-dib0700-rc5"
  "rc-digitalnow-tinytwin"
  "rc-digittrade"
  "rc-dm1105-nec"
  # https://github.com/torvalds/linux/blob/master/drivers/media/pci/dm1105/dm1105.c
  "dm1105"
  "rc-dntv-live-dvb-t"
  "rc-dntv-live-dvbt-pro"
  "rc-dreambox"
  "rc-dtt200u"
  "rc-dvbsky"
  "rc-dvico-mce"
  "rc-dvico-portable"
  "rc-em-terratec"
  "rc-encore-enltv"
  "rc-encore-enltv2"
  "rc-encore-enltv-fm53"
  "rc-evga-indtube"
  "rc-eztv"
  "rc-flydvb"
  "rc-flyvideo"
  "rc-fusionhdtv-mce"
  "rc-gadmei-rm008z"
  "rc-geekbox"
  "rc-genius-tvgo-a11mce"
  "rc-gotview7135"
  "rc-hauppauge"
  "rc-hisi-poplar"
  "rc-hisi-tv-demo"
  "rc-imon-mce"
  "rc-imon-pad"
  "rc-imon-rsc"
  "rc-iodata-bctv7e"
  "rc-it913x-v1"
  "rc-it913x-v2"
  "rc-kaiomy"
  "rc-khadas"
  "rc-khamsin"
  "rc-kworld-315u"
  "rc-kworld-pc150u"
  "rc-kworld-plus-tv-analog"
  "rc-leadtek-y04g0051"
  "rc-lme2510"
  "rc-loopback"
  "rc-manli"
  "rc-mecool-kiii-pro"
  "rc-mecool-kii-pro"
  "rc-medion-x10"
  "rc-medion-x10-digitainer"
  "rc-medion-x10-or2x"
  "rc-minix-neo"
  "rc-msi-digivox-ii"
  "rc-msi-digivox-iii"
  "rc-msi-tvanywhere"
  "rc-msi-tvanywhere-plus"
  "rc-mygica-utv3"
  "rc-nebula"
  "rc-nec-terratec-cinergy-xs"
  "rc-norwood"
  "rc-npgtech"
  "rc-odroid"
  "rc-pctv-sedna"
  "rc-pine64"
  "rc-pinnacle-color"
  "rc-pinnacle-grey"
  "rc-pinnacle-pctv-hd"
  "rc-pixelview"
  "rc-pixelview-002t"
  "rc-pixelview-mk12"
  "rc-pixelview-new"
  "rc-powercolor-real-angel"
  "rc-proteus-2309"
  "rc-purpletv"
  "rc-pv951"
  "rc-rc6-mce"
  "rc-real-audio-220-32-keys"
  "rc-reddo"
  "rc-siemens-gigaset-rc20"
  "rc-snapstream-firefly"
  "rc-streamzap"
  "rc-su3000"
  "rc-tanix-tx3mini"
  "rc-tanix-tx5max"
  "rc-tbs-nec"
  "rc-technisat-ts35"
  "rc-technisat-usb2"
  "rc-terratec-cinergy-c-pci"
  "rc-terratec-cinergy-s2-hd"
  "rc-terratec-cinergy-xs"
  "rc-terratec-slim"
  "rc-terratec-slim-2"
  "rc-tevii-nec"
  "rc-tivo"
  "rc-total-media-in-hand"
  "rc-total-media-in-hand-02"
  "rc-trekstor"
  "rc-tt-1500"
  "rc-twinhan1027"
  "rc-twinhan-dtv-cab-ci"
  "rc-vega-s9x"
  "rc-videomate-m1f"
  "rc-videomate-s350"
  "rc-videomate-tv-pvr"
  "rc-videostrong-kii-pro"
  "rc-wetek-hub"
  "rc-wetek-play2"
  "rc-winfast"
  "rc-winfast-usbii-deluxe"
  "rc-x96max"
  "rc-xbox-360"
  "rc-xbox-dvd"
  "rc-zx-irdec"
  # https://github.com/torvalds/linux/tree/master/drivers/media/rc
  "ati_remote"
  "ati_remote2"
  "ene_ir"
  "fintek-cir"
  "igorplugusb"
  "iguanair"
  "imon"
  "imon_raw"
  "ir-imon-decoder"
  "ir-jvc-decoder"
  # https://github.com/torvalds/linux/blob/master/drivers/media/i2c/ir-kbd-i2c.c
  "ir-kbd-i2c"
  "ir-mce_kbd-decoder"
  "ir-nec-decoder"
  "ir-rc5-decoder"
  "ir-rc6-decoder"
  "ir-rcmm-decoder"
  "ir-sanyo-decoder"
  "ir-sharp-decoder"
  "ir-sony-decoder"
  # https://github.com/torvalds/linux/blob/master/drivers/usb/serial/ir-usb.c
  "ir-usb"
  "ir_toy"
  "ir-xmp-decoder"
  "ite-cir"
  "mceusb"
  "nuvoton-cir"
  "serial_ir"
  "streamzap"
  "ttusbir"
  "winbond-cir"
  "xbox_remote"

  # legacy digital cameras (pre-2010)
  # note this often refers to point-and-shoot digital cameras
  # predating usb webcams, e.g. Kodak EZ200, Fujifilm FinePix F402, etc.
  # https://www.linuxtv.org/wiki/index.php/install gspca_devices
  "gspca_benq"
  "gspca_conex"
  "gspca_cpia1"
  "gspca_dtcs033"
  "gspca_etoms"
  "gspca_finepix"
  "gspca_gl860"
  "gspca_jeilinj"
  "gspca_jl2005bcd"
  "gspca_kinect"
  "gspca_konica"
  "gspca_m5602"
  "gspca_main"
  "gspca_mars"
  "gspca_mr97310a"
  "gspca_nw80x"
  "gspca_ov519"
  "gspca_ov534"
  "gspca_ov534_9"
  "gspca_pac207"
  "gspca_pac7302"
  "gspca_pac7311"
  "gspca_se401"
  "gspca_sn9c2028"
  "gspca_sn9c20x"
  "gspca_sonixb"
  "gspca_sonixj"
  "gspca_spca1528"
  "gspca_spca500"
  "gspca_spca501"
  "gspca_spca505"
  "gspca_spca506"
  "gspca_spca508"
  "gspca_spca561"
  "gspca_sq905"
  "gspca_sq905c"
  "gspca_sq930x"
  "gspca_stk014"
  "gspca_stk1135"
  "gspca_stv0680"
  "gspca_stv06xx"
  "gspca_sunplus"
  "gspca_t613"
  "gspca_topro"
  "gspca_touptek"
  "gspca_tv8532"
  "gspca_vc032x"
  "gspca_vicam"
  "gspca_xirlink_cit"
  "gspca_zc3xx"

  # radio tuners
  # https://github.com/torvalds/linux/tree/master/drivers/media/radio
  # https://legacyfiles.us.dlink.com/DSB-R100/REVA/DSB-R100_QIG_6.00B_EN.PDF
  "dsbr100"
  "radio-keene"
  "radio-ma901"
  "radio-maxiradio"
  "radio-mr800"
  "radio-shark"
  # https://github.com/torvalds/linux/blob/master/drivers/media/radio/radio-shark2.c
  "shark2"
  "radio-si470x-common"
  "radio-si470x-i2c"
  "radio-si470x-usb"
  "radio-tea5764"
  "saa7706h"
]
