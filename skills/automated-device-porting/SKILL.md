---
name: automated-device-porting
description: Use when reviving a phone, tablet or other locked consumer device onto LosOS, judging whether a bootloader can be unlocked, running adb, fastboot, heimdall or scrcpy against an attached device, dumping or flashing a boot, recovery or system image, choosing between Halium and a Treble GSI, or building a harness that ports devices with nobody watching.
---

# Automated device porting

## Context

A drawer of retired phones becomes a rack
once someone does the boring part, and that
part is what an agent is for. The failure
mode here is a dead board, not a red build.

## Rules

1. Identify first: `adb shell getprop
   ro.product.device`, `fastboot getvar
   product`, `heimdall print-pit` on Samsung.
   `lsusb` names the mode, not the model.
2. Match every image to the reported codename.
   A sibling shares the name, not the map.
3. Dump boot, recovery, persist, modem and
   efs first. A lost efs takes the IMEI.
4. Never flash firmware older than what is
   installed. Rollback fuses burn one way.
5. Toggle OEM unlocking inside booted
   Android, then `fastboot flashing unlock`
   or `oem unlock`. It wipes userdata.
6. Some units never unlock: carrier locks,
   Knox fuses, vendor waits. Take the next.
7. Prove with `fastboot boot` before `flash`.
8. Verify by readback hash. `OKAY` means
   sent, not written.
9. Flash vbmeta with `--disable-verity` and
   `--disable-verification` or it loops.
10. Repack when no patched TWRP fits: dump
    stock boot.img, rebuild with `mkbootimg`.
11. Drive in-Android dialogs with scrcpy in a
    nested compositor. The bootloader prompt
    is a key press no software can reach.
12. Write the harness in any language that
    removes the last human step. Log per unit.
13. GSI when `ro.treble.enabled` is true and
    Android 9+ launched, else Halium. Flash
    system after `fastboot reboot fastboot`.
14. Open ghidra or cutter on blobs or the
    kernel only after a documented port failed.

## Rationalizations to reject

| Excuse | Why it fails |
|---|---|
| "The guide is for a close-enough model" | Close-enough models share a marketing name and not a partition table. That is how boards die. |
| "Backing up efs wastes time" | It costs a minute. Restoring an IMEI you never dumped costs the phone. |
| "Flash it and see whether it boots" | A boot loop is the cheap outcome. The burned rollback fuse is the other one. |
| "The flash printed OKAY" | That is the transfer's receipt, not the partition's. Read it back. |
| "I will watch this one by hand" | Then the next forty are by hand. Automate the dialog once. |
| "A watchdog can retry a killed flash" | A half-written partition has no good copy left to retry from. |

## Target audience

- **fucking don't care**: flashes the first
  zip matching the marketing name.
- **don't care**: reads the thread, skips
  the backups.
- **care**: dumps efs and verifies.
- **really care**: automates it so device
  forty costs what device one did.
- **Matus**: the last two, and wants the
  rack on LosOS unattended.

## Post-run checklist

- [ ] Codename read off the device?
- [ ] efs, modem, persist archived off-device?
- [ ] Flash verified by readback hash?
- [ ] Device cold-booted twice unaided?
- [ ] Per-device note left behind?
