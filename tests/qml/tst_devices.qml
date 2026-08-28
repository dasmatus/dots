// Pins qml/services/devices.js against a real `lsblk -J -b` capture from this
// machine (.superpowers/sdd/rosy-zooming-lemon/lsblk-fixture.json, embedded
// below rather than read from disk so this test needs no
// QML_XHR_ALLOW_FILE_READ flag).
//
// The two cases that matter most are both in that fixture without any
// editing: /dev/sda1 is a real USB hard disk with rm:false, and
// /dev/nvme0n1p1 is the real EFI System Partition, sitting there with a
// filesystem and no reason to be offered as mountable. A device filter that
// reaches for the wrong column passes every case that doesn't include one of
// these two.
import QtQuick
import QtTest
import "../../nix/home/quickshell/qml/services/devices.js" as Devices

TestCase {
    name: "Devices"

    // Captured verbatim from .superpowers/sdd/rosy-zooming-lemon/lsblk-fixture.json.
    property string fixture: `{
   "blockdevices": [
      {
         "name": "loop0",
         "path": "/dev/loop0",
         "label": null,
         "size": 57344,
         "fstype": "erofs",
         "mountpoint": null,
         "rm": false,
         "hotplug": false,
         "type": "loop",
         "vendor": null,
         "model": null
      },{
         "name": "sda",
         "path": "/dev/sda",
         "label": null,
         "size": 2000365289472,
         "fstype": null,
         "mountpoint": null,
         "rm": false,
         "hotplug": true,
         "type": "disk",
         "vendor": "WD      ",
         "model": "WDC WD20SDZW-59Z3CS0",
         "children": [
            {
               "name": "sda1",
               "path": "/dev/sda1",
               "label": null,
               "size": 2000363192320,
               "fstype": "exfat",
               "mountpoint": null,
               "rm": false,
               "hotplug": true,
               "type": "part",
               "vendor": null,
               "model": null
            }
         ]
      },{
         "name": "nvme0n1",
         "path": "/dev/nvme0n1",
         "label": null,
         "size": 512110190592,
         "fstype": null,
         "mountpoint": null,
         "rm": false,
         "hotplug": false,
         "type": "disk",
         "vendor": null,
         "model": "Micron_2500_MTFDKBA512QGN",
         "children": [
            {
               "name": "nvme0n1p1",
               "path": "/dev/nvme0n1p1",
               "label": null,
               "size": 2147483648,
               "fstype": "vfat",
               "mountpoint": "/boot",
               "rm": false,
               "hotplug": false,
               "type": "part",
               "vendor": null,
               "model": null
            },{
               "name": "nvme0n1p2",
               "path": "/dev/nvme0n1p2",
               "label": null,
               "size": 509961306112,
               "fstype": "LVM2_member",
               "mountpoint": null,
               "rm": false,
               "hotplug": false,
               "type": "part",
               "vendor": null,
               "model": null,
               "children": [
                  {
                     "name": "tokyonightvg-swap",
                     "path": "/dev/mapper/tokyonightvg-swap",
                     "label": null,
                     "size": 16106127360,
                     "fstype": null,
                     "mountpoint": null,
                     "rm": false,
                     "hotplug": false,
                     "type": "lvm",
                     "vendor": null,
                     "model": null,
                     "children": [
                        {
                           "name": "dev-tokyonightvg-swap",
                           "path": "/dev/mapper/dev-tokyonightvg-swap",
                           "label": null,
                           "size": 16106127360,
                           "fstype": "swap",
                           "mountpoint": "[SWAP]",
                           "rm": false,
                           "hotplug": false,
                           "type": "crypt",
                           "vendor": null,
                           "model": null
                        }
                     ]
                  },{
                     "name": "tokyonightvg-root",
                     "path": "/dev/mapper/tokyonightvg-root",
                     "label": null,
                     "size": 493854130176,
                     "fstype": "crypto_LUKS",
                     "mountpoint": null,
                     "rm": false,
                     "hotplug": false,
                     "type": "lvm",
                     "vendor": null,
                     "model": null,
                     "children": [
                        {
                           "name": "cryptroot",
                           "path": "/dev/mapper/cryptroot",
                           "label": null,
                           "size": 493837352960,
                           "fstype": "btrfs",
                           "mountpoint": "/etc/NetworkManager/system-connections",
                           "rm": false,
                           "hotplug": false,
                           "type": "crypt",
                           "vendor": null,
                           "model": null
                        }
                     ]
                  }
               ]
            }
         ]
      }
   ]
}
`

    function byPath(devices, path) {
        for (const d of devices) {
            if (d.path === path)
                return d;
        }
        return null;
    }

    // A hotplug USB disk carrying LUKS-then-LVM: the partition holds
    // crypto_LUKS and no mountpoint (locked at the lsblk level would show
    // no children at all, but here it is already unlocked, so lsblk shows
    // the mapper device as a child); the crypt mapping is itself an LVM
    // physical volume with no mountpoint of its own; the logical volume on
    // top carries the real filesystem and mountpoint. Same node types as
    // this machine's own internal disk (see lsblk-fixture.json's
    // nvme0n1p2 chain), reused here to prove the eject path handles them
    // when they sit on a disk that is hotplug instead of the boot disk.
    // The crypt and lvm nodes both report hotplug:false on themselves,
    // exactly as lsblk reports it for real device-mapper nodes regardless
    // of what bus the disk underneath is on.
    function luksLvmFixture() {
        return JSON.stringify({
            blockdevices: [
                {
                    name: "sde",
                    path: "/dev/sde",
                    label: null,
                    size: 1000204886016,
                    fstype: null,
                    mountpoint: null,
                    rm: false,
                    hotplug: true,
                    type: "disk",
                    vendor: "Samsung",
                    model: "Portable SSD",
                    children: [
                        {
                            name: "sde1",
                            path: "/dev/sde1",
                            label: null,
                            size: 1000202780672,
                            fstype: "crypto_LUKS",
                            mountpoint: null,
                            rm: false,
                            hotplug: true,
                            type: "part",
                            vendor: null,
                            model: null,
                            children: [
                                {
                                    name: "luks-sde1",
                                    path: "/dev/mapper/luks-sde1",
                                    label: null,
                                    size: 1000185999872,
                                    fstype: "LVM2_member",
                                    mountpoint: null,
                                    rm: false,
                                    hotplug: false,
                                    type: "crypt",
                                    vendor: null,
                                    model: null,
                                    children: [
                                        {
                                            name: "vgexternal-data",
                                            path: "/dev/mapper/vgexternal-data",
                                            label: null,
                                            size: 1000185999872,
                                            fstype: "ext4",
                                            mountpoint: "/run/media/matus/data",
                                            rm: false,
                                            hotplug: false,
                                            type: "lvm",
                                            vendor: null,
                                            model: null
                                        }
                                    ]
                                }
                            ]
                        }
                    ]
                }
            ]
        });
    }

    // If this filtered on rm instead of hotplug, sda1 (rm:false) would be
    // the first thing dropped — it's a real USB hard disk, not "removable
    // media" in the SCSI-bit sense, and the fixture captures it exactly as
    // udisksctl-based mounting needs it to look: hotplug, rm:false.
    function test_real_usb_disk_with_rm_false_is_included() {
        const devices = Devices.parseDevices(fixture);
        const sda1 = byPath(devices, "/dev/sda1");

        verify(sda1 !== null, "sda1 (rm:false, hotplug:true) must be included");
        compare(sda1.hotplug, true);
        compare(sda1.fstype, "exfat");
        compare(sda1.diskPath, "/dev/sda");
    }

    // The case that stops the shell trying to mount the ESP: a vfat
    // partition with a filesystem, sitting on a non-hotplug internal disk.
    function test_efi_system_partition_is_excluded() {
        const devices = Devices.parseDevices(fixture);
        verify(byPath(devices, "/dev/nvme0n1p1") === null, "the ESP must never be offered as mountable");
    }

    function test_loop_device_in_fixture_is_excluded() {
        const devices = Devices.parseDevices(fixture);
        verify(byPath(devices, "/dev/loop0") === null);
    }

    // loop0 in the fixture is also hotplug:false, so excluding it there
    // doesn't prove the type check fired rather than the hotplug check.
    // This constructs a loop device that IS hotplug, to isolate the rule
    // "type loop is excluded always".
    function test_hotplug_loop_device_is_still_excluded() {
        const hotplugLoop = JSON.stringify({
            blockdevices: [
                {
                    name: "loop9",
                    path: "/dev/loop9",
                    label: null,
                    size: 1024,
                    fstype: "ext4",
                    mountpoint: null,
                    rm: true,
                    hotplug: true,
                    type: "loop",
                    vendor: null,
                    model: null
                }
            ]
        });

        compare(Devices.parseDevices(hotplugLoop).length, 0);
    }

    // The LVM/crypt chain under nvme0n1p2 must contribute nothing: none of
    // lvm, crypt or the swap mapper device are type "part" or a childless
    // "disk", and none of it is hotplug either.
    function test_lvm_and_crypt_plumbing_is_excluded() {
        const devices = Devices.parseDevices(fixture);
        compare(devices.length, 1);
        compare(devices[0].path, "/dev/sda1");
    }

    function test_display_label_data() {
        return [
            { tag: "label wins", device: { label: "BACKUP", vendor: "WD      ", model: "Elements", name: "sda1" }, expected: "BACKUP" },
            { tag: "vendor padding is trimmed", device: { label: null, vendor: "WD      ", model: "WDC WD20SDZW-59Z3CS0", name: "sda" }, expected: "WD WDC WD20SDZW-59Z3CS0" },
            { tag: "model only", device: { label: null, vendor: null, model: "Elements", name: "sda1" }, expected: "Elements" },
            { tag: "falls back to name", device: { label: null, vendor: null, model: null, name: "sda1" }, expected: "sda1" },
            { tag: "empty label falls through", device: { label: "", vendor: null, model: null, name: "sda1" }, expected: "sda1" }
        ];
    }

    function test_display_label(row) {
        compare(Devices.displayLabel(row.device), row.expected);
    }

    function test_mount_candidates_skips_mounted_and_attempted() {
        const devices = [
            { path: "/dev/sda1", mountPoint: null, fstype: "exfat" },
            { path: "/dev/sdb1", mountPoint: "/run/media/sdb1", fstype: "ext4" },
            { path: "/dev/sdc1", mountPoint: null, fstype: "ext4" },
            { path: "/dev/sdd1", mountPoint: null, fstype: null }
        ];
        const attempted = { "/dev/sdc1": true };

        const candidates = Devices.mountCandidates(devices, attempted);

        compare(candidates.length, 1);
        compare(candidates[0].path, "/dev/sda1");
    }

    function test_prune_attempts_drops_unplugged_keeps_present() {
        const attempted = { "/dev/sda1": true, "/dev/sdz1": true };
        const devices = [{ path: "/dev/sda1" }];

        const pruned = Devices.pruneAttempts(attempted, devices);

        verify(Object.prototype.hasOwnProperty.call(pruned, "/dev/sda1"));
        verify(!Object.prototype.hasOwnProperty.call(pruned, "/dev/sdz1"));
    }

    // Finding 1: a device already mounted the first time a scan ever sees
    // it, from a previous session or by any tool other than this shell,
    // never went through mount(), so `attempted` had no entry for it. The
    // four cases below are the ones the fix must hold simultaneously,
    // exercised through the same three-step order Devices.qml's applyScan
    // now runs: pruneAttempts, then seedAttempts, then mountCandidates.

    // A freshly plugged, unmounted disk must still automount: seeding never
    // touches a path with no mountPoint, so it stays a candidate.
    function test_seed_attempts_leaves_a_freshly_plugged_unmounted_disk_a_candidate() {
        const devices = [{ path: "/dev/sda1", mountPoint: null, fstype: "exfat" }];

        const seeded = Devices.seedAttempts({}, devices);
        const candidates = Devices.mountCandidates(devices, seeded);

        verify(!Object.prototype.hasOwnProperty.call(seeded, "/dev/sda1"));
        compare(candidates.length, 1);
    }

    // A disk already mounted when the singleton runs its very first scan,
    // `attempted` starting out {}, must come out of that scan seeded, not
    // just skipped for being mounted right now.
    function test_seed_attempts_marks_a_disk_already_mounted_at_first_scan() {
        const devices = [{ path: "/dev/sda1", mountPoint: "/run/media/sda1", fstype: "exfat" }];

        const seeded = Devices.seedAttempts({}, devices);

        verify(Object.prototype.hasOwnProperty.call(seeded, "/dev/sda1"));
    }

    // The bug itself: a device this shell never mounted (so `attempted`
    // starts empty for it) is seen mounted on scan one, seeded there, then
    // manually unmounted with `udisksctl unmount` by hand before scan two.
    // pruneAttempts must not drop it, because the path never left lsblk, so
    // the seeded mark from scan one survives and mountCandidates must not
    // offer it back.
    function test_seed_attempts_keeps_a_manual_unmount_from_being_undone() {
        const mountedScan = [{ path: "/dev/sda1", mountPoint: "/run/media/sda1", fstype: "exfat" }];
        const afterManualUnmount = [{ path: "/dev/sda1", mountPoint: null, fstype: "exfat" }];

        let attempted = Devices.seedAttempts({}, mountedScan);

        attempted = Devices.pruneAttempts(attempted, afterManualUnmount);
        attempted = Devices.seedAttempts(attempted, afterManualUnmount);
        const candidates = Devices.mountCandidates(afterManualUnmount, attempted);

        compare(candidates.length, 0, "a manually unmounted device must not be re-offered as a mount candidate");
    }

    // Unplug then replug must mount again: pruneAttempts drops the path
    // once it vanishes from lsblk entirely, so the seeded mark from before
    // the unplug does not survive to block the replug.
    function test_seed_attempts_allows_remount_after_unplug_and_replug() {
        const mountedScan = [{ path: "/dev/sda1", mountPoint: "/run/media/sda1", fstype: "exfat" }];
        const unplugged = [];
        const repluggedUnmounted = [{ path: "/dev/sda1", mountPoint: null, fstype: "exfat" }];

        let attempted = Devices.seedAttempts({}, mountedScan);

        attempted = Devices.pruneAttempts(attempted, unplugged);
        attempted = Devices.seedAttempts(attempted, unplugged);

        attempted = Devices.pruneAttempts(attempted, repluggedUnmounted);
        attempted = Devices.seedAttempts(attempted, repluggedUnmounted);
        const candidates = Devices.mountCandidates(repluggedUnmounted, attempted);

        compare(candidates.length, 1, "a replugged device must be eligible again after it fully vanished from lsblk");
    }

    function test_newly_mounted_detects_transition_ignores_unchanged() {
        const previous = [
            { path: "/dev/sda1", mountPoint: null },
            { path: "/dev/sdb1", mountPoint: "/run/media/sdb1" }
        ];
        const next = [
            { path: "/dev/sda1", mountPoint: "/run/media/sda1" },
            { path: "/dev/sdb1", mountPoint: "/run/media/sdb1" }
        ];

        const changed = Devices.newlyMounted(previous, next);

        compare(changed.length, 1);
        compare(changed[0].path, "/dev/sda1");
    }

    function test_newly_mounted_ignores_a_device_that_stays_unmounted() {
        const previous = [{ path: "/dev/sda1", mountPoint: null }];
        const next = [{ path: "/dev/sda1", mountPoint: null }];

        compare(Devices.newlyMounted(previous, next).length, 0);
    }

    // The whole point of the argv split, mirrored from
    // tst_preview.qml's test_preview_command_keeps_the_path_out_of_the_script:
    // a mount label or a filename inside the device is data the shell must
    // never interpret, so the path has to survive as one argv element, never
    // as text folded into another one.
    function test_command_builders_keep_the_path_as_one_argv_element_data() {
        const hostile = "/dev/disk/by-label/my \" ; rm -rf ~ ; \" disk";
        return [
            { tag: "mount", argv: Devices.mountCommand(hostile), hostile: hostile },
            { tag: "unmount", argv: Devices.unmountCommand(hostile), hostile: hostile },
            { tag: "power-off", argv: Devices.powerOffCommand(hostile), hostile: hostile }
        ];
    }

    function test_command_builders_keep_the_path_as_one_argv_element(row) {
        compare(row.argv[0], "udisksctl");
        verify(row.argv.indexOf(row.hostile) !== -1, "the hostile path must appear as its own argv element");

        for (const arg of row.argv) {
            if (arg === row.hostile)
                continue;
            verify(arg.indexOf(row.hostile) === -1, "the hostile path must not be folded into another argv element");
        }

        verify(row.argv.join(" ").split(row.hostile).length - 1 === 1, "the hostile path must appear exactly once across the whole argv");
    }

    function test_eject_plan_unmounts_every_mounted_partition_then_powers_off() {
        const hostile = "/dev/disk/by-id/my \" ; rm -rf ~ ; \" disk";
        const devices = [
            { path: "/dev/sda", diskPath: hostile, type: "disk", mountPoint: null },
            { path: "/dev/sda1", diskPath: hostile, type: "part", mountPoint: "/run/media/sda1" },
            { path: "/dev/sda2", diskPath: hostile, type: "part", mountPoint: null },
            { path: "/dev/sdb1", diskPath: "/dev/sdb", type: "part", mountPoint: "/run/media/sdb1" }
        ];

        const plan = Devices.ejectPlan(devices, hostile);

        compare(plan.length, 2);
        compare(plan[0], Devices.unmountCommand("/dev/sda1"));
        compare(plan[1], Devices.powerOffCommand(hostile));
        verify(plan[1].indexOf(hostile) !== -1);
    }

    // A superfloppy is a whole "disk" carrying a filesystem directly, no
    // partition table, no children — parseDevices sets its diskPath to its
    // own path and leaves type "disk". A plan that only looks for type
    // "part" would skip its unmount and power the disk off still mounted,
    // the closest thing to data loss in this file.
    function test_eject_plan_unmounts_a_mounted_superfloppy_before_powering_off() {
        const diskPath = "/dev/sdc";
        const devices = [
            { path: diskPath, diskPath: diskPath, type: "disk", fstype: "exfat", mountPoint: "/run/media/sdc", hotplug: true }
        ];

        const plan = Devices.ejectPlan(devices, diskPath);

        compare(plan.length, 2);
        compare(plan[0], Devices.unmountCommand(diskPath));
        compare(plan[1], Devices.powerOffCommand(diskPath));

        // powerOffCommand and unmountCommand each build a fresh array, so
        // ordering has to be checked by content, not by indexOf identity:
        // every step before the last must be a `udisksctl unmount`, and
        // only the last step may be the `udisksctl power-off`.
        for (let i = 0; i < plan.length - 1; i++)
            verify(plan[i][1] === "unmount", "every step before the power-off must be an unmount");
        verify(plan[plan.length - 1][1] === "power-off", "the power-off must be the last step");
    }

    // The regression this whole fixture exists for: automount must stay
    // narrow even though the disk carrying this LUKS/LVM chain is hotplug.
    // A careless fix that widens walk()'s push condition to "chase the
    // eject bug" would light this test up.
    function test_parse_devices_excludes_luks_and_lvm_even_on_a_hotplug_disk() {
        const devices = Devices.parseDevices(luksLvmFixture());

        verify(byPath(devices, "/dev/mapper/luks-sde1") === null, "a crypt mapping must never be offered for automount");
        verify(byPath(devices, "/dev/mapper/vgexternal-data") === null, "an lvm logical volume must never be offered for automount");
    }

    // parseMounts answers a different question than parseDevices: not
    // "what should this shell offer to mount" but "what is mounted right
    // now, under this disk, whatever it is". The lvm leaf is what
    // ejectPlan needs and parseDevices() would never surface.
    function test_parse_mounts_finds_the_lvm_node_mounted_under_luks() {
        const mounts = Devices.parseMounts(luksLvmFixture());
        const lvm = byPath(mounts, "/dev/mapper/vgexternal-data");

        verify(lvm !== null, "the mounted lvm node must appear in parseMounts' output");
        compare(lvm.diskPath, "/dev/sde");
        compare(lvm.mountPoint, "/run/media/matus/data");
        compare(lvm.type, "lvm");
    }

    // The crypt mapping under sde1 is itself flagged hotplug:false by
    // lsblk, same as real device-mapper nodes always are, regardless of
    // what bus the disk underneath sits on. If ejectPlan's guard read that
    // per-node flag instead of the flag carried down from the top-level
    // disk, it would refuse to power off a disk that is genuinely hotplug.
    function test_parse_mounts_carries_disk_hotplug_not_the_mapped_nodes_own_flag() {
        const mounts = Devices.parseMounts(luksLvmFixture());
        const lvm = byPath(mounts, "/dev/mapper/vgexternal-data");

        verify(lvm !== null);
        compare(lvm.hotplug, true, "hotplug must come from the top-level disk, not the lvm node's own false flag");
    }

    // The bug itself, reproduced end to end: ejectPlan fed the broad
    // parseMounts() list must find the mounted lvm node sitting three
    // levels under the disk it is ejecting and unmount it before cutting
    // power, not hand back a bare power-off against a live filesystem.
    function test_eject_plan_unmounts_luks_lvm_chain_before_power_off() {
        const diskPath = "/dev/sde";
        const mounts = Devices.parseMounts(luksLvmFixture());

        const plan = Devices.ejectPlan(mounts, diskPath);

        let powerOffIndex = -1;
        let powerOffCount = 0;
        for (let i = 0; i < plan.length; i++) {
            if (plan[i][1] === "power-off") {
                powerOffCount++;
                powerOffIndex = i;
            }
        }
        compare(powerOffCount, 1, "power-off must appear exactly once");
        compare(powerOffIndex, plan.length - 1, "power-off must be the last step");

        for (let i = 0; i < plan.length - 1; i++)
            verify(plan[i][1] === "unmount", "every step before the power-off must be an unmount");

        const lvmUnmount = Devices.unmountCommand("/dev/mapper/vgexternal-data");
        let unmountsLvm = false;
        for (const step of plan) {
            if (JSON.stringify(step) === JSON.stringify(lvmUnmount))
                unmountsLvm = true;
        }
        verify(unmountsLvm, "the mounted lvm node must be unmounted before the disk loses power");
        compare(plan[plan.length - 1], Devices.powerOffCommand(diskPath));
    }

    // Defence in depth: whatever diskPath a caller hands ejectPlan, a
    // mounted node under it that is known, via the disk-level hotplug flag
    // parseMounts carries down, to sit on a non-hotplug disk must never
    // result in a power-off step. This is what stands between a wrong
    // diskPath and powering off the machine's own NVMe mid-session.
    function test_eject_plan_never_powers_off_a_non_hotplug_disk() {
        const diskPath = "/dev/nvme0n1";
        const mounts = [
            { path: "/dev/nvme0n1p1", diskPath: diskPath, mountPoint: "/boot", type: "part", hotplug: false }
        ];

        const plan = Devices.ejectPlan(mounts, diskPath);

        for (const step of plan)
            verify(step[1] !== "power-off", "a non-hotplug disk must never receive a power-off step");
    }
}
