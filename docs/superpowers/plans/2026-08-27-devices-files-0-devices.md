# Devices & Files 0: Devices Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use
> superpowers:subagent-driven-development or superpowers:executing-plans.

**Goal:** A plugged-in USB/SD device automounts with no daemon but the shell
itself, and becomes visible on the bar and in the launcher. No file manager
yet, that is Plan 1.
**Architecture:** `qml/services/Devices.qml`, a `pragma Singleton` shaped
like `qml/monitors/Watcher.qml`: a persistent `udevadm monitor` `Process`
debounces into an `lsblk -J -b` rescan, which drives `udisksctl mount` for
anything that qualifies. `bar/Drives.qml` and `Providers.qml`'s new
`deviceRows()` both read the singleton's `devices` property; nothing
instantiates it explicitly, because reading it is what constructs it.
**Tech Stack:** Quickshell 0.3, Qt 6.11, `udisksctl`/`udevadm`/`lsblk` from
`util-linux`/`udisks2` (already on `PATH`), QtTest.
**Spec:** `docs/superpowers/specs/2026-08-27-devices-files-design.md`

## Global Constraints
- `lsblk` is invoked only as `-J -b -o <columns>`. Never bare `lsblk`, never
  without `-b`, this machine's locale prints `"1,8T"` with a comma.
- `udisksctl`'s stdout is read for nothing. Only its exit code, followed by
  a fresh `lsblk` rescan to learn the real resulting state.
- The automount filter is two stages, matching what `devices.js` actually
  exports. `parseDevices(text)` walks the raw `lsblk` tree and keeps only
  hotplug partitions and hotplug superfloppy disks that carry an `fstype`,
  so `hotplug` is the clause that keeps the EFI System Partition out of the
  parsed list at all: `/dev/nvme0n1p1` reports `fstype: "vfat", mountpoint:
  "/boot", hotplug: false`, always mounted, so without a hotplug clause it
  would still show up as a device on every scan. Never `rm` either:
  `/dev/sda1`, the real USB disk's partition, reports `rm: false` too, so
  an rm-based filter would wrongly drop it while still excluding the ESP
  the same way, which is not a distinction rm can make.
  `mountCandidates(devices, attempted)` then narrows that already-hotplug
  list to `!mountPoint && fstype && !attempted[path]`: still needs
  mounting, and not already the target of a mount this singleton started
  and is still waiting on.
- `qmllint --max-warnings 0` over the whole tree, unchanged gate
  (`nix run .#nix-lint`).
- `Devices` is a `pragma Singleton`. No `Devices {}` line is ever added to
  `shell.qml`, the point of Task 2 is proving the singleton comes alive
  from being *read*, the same way `Theme.qml` already does.

---

### Task 1: `devices.js`, pure classification, TDD against the real fixture

**Files:**
- Create: `tests/qml/fixtures/lsblk-devices.json`
- Create: `nix/home/desktop/quickshell/qml/services/devices.js`
- Create: `tests/qml/tst_devices.qml`

**Produces:** `devices.js` exporting `parseDevices(text)`,
`displayLabel(device)`, `mountCandidates(devices, attempted)`,
`pruneAttempts(attempted, devices)`, `newlyMounted(previous, next)`,
`mountCommand(path)`, `unmountCommand(path)`, `powerOffCommand(path)`,
`ejectPlan(devices, diskPath)`. No `PKNAME` lookup and no reuse of
`qml/installer/disks.js`'s `parentDisk(path)`: the same tree walk that
builds the parsed list already knows which top-level disk each partition
descends from, so every record carries its own `diskPath`, and `ejectPlan`
reads it straight off the record instead of resolving it a second way.

- [ ] **1** `cp .superpowers/sdd/rosy-zooming-lemon/lsblk-fixture.json tests/qml/fixtures/lsblk-devices.json`
      Expected: `git status` shows the new file under `tests/qml/fixtures/`

- [ ] **2** Write `tests/qml/tst_devices.qml`:

```qml
// Proves the hotplug clause exists at all: /dev/nvme0n1p1, the EFI System
// Partition, has an fstype and is always mounted at /boot with hotplug
// false. Drop the hotplug clause and it would still pass every other
// check and land in the device list next to /dev/sda1, the real USB disk.
// This fixture is a genuine `lsblk -J -b` capture carrying both side by
// side.
//
// Reading the fixture needs QML_XHR_ALLOW_FILE_READ=1 (flake/apps.nix
// already sets it on the qmltestrunner invocation, see tst_installer.qml).
import QtQuick
import QtTest
import "../../nix/home/desktop/quickshell/qml/services/devices.js" as Devices

TestCase {
    name: "Devices"

    property string fixtureJson: ""

    function initTestCase() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("fixtures/lsblk-devices.json"), false);
        xhr.send();
        compare(xhr.status, 200, "fixture must be readable (needs QML_XHR_ALLOW_FILE_READ=1)");
        fixtureJson = xhr.responseText;
    }

    function byPath(devices, path) {
        for (const d of devices) {
            if (d.path === path)
                return d;
        }
        return null;
    }

    function test_real_usb_disk_with_rm_false_is_included() {
        const devices = Devices.parseDevices(fixtureJson);
        const sda1 = byPath(devices, "/dev/sda1");

        verify(sda1 !== null, "sda1 (rm:false, hotplug:true) must be included, got " + JSON.stringify(devices.map(d => d.path)));
        compare(sda1.diskPath, "/dev/sda");
    }

    function test_efi_system_partition_is_excluded() {
        const devices = Devices.parseDevices(fixtureJson);
        verify(byPath(devices, "/dev/nvme0n1p1") === null, "must not offer to mount the ESP");
    }

    function test_lvm_and_crypt_plumbing_is_excluded() {
        // cryptroot sits four levels deep under nvme0n1p2 -> LVM -> LUKS.
        // parseDevices walks that deep but keeps nothing from the chain: it
        // is neither hotplug nor type "part" nor a childless "disk", the
        // same reason loop0 at the top level is also excluded. Asserting
        // the whole list is exactly sda1 proves the walk descends past the
        // one candidate without also picking up the plumbing beside it.
        const devices = Devices.parseDevices(fixtureJson);
        compare(devices.length, 1);
        compare(devices[0].path, "/dev/sda1");
    }

    function test_displaylabel_falls_back_from_label_to_model_to_name() {
        compare(Devices.displayLabel({ name: "sda1", label: "BACKUP", vendor: null, model: "WDC WD20SDZW" }), "BACKUP");
        compare(Devices.displayLabel({ name: "sda1", label: null, vendor: null, model: "WDC WD20SDZW-59Z3CS0" }), "WDC WD20SDZW-59Z3CS0");
        compare(Devices.displayLabel({ name: "sda1", label: null, vendor: null, model: null }), "sda1");
    }

    function test_mount_candidates_skips_mounted_and_attempted() {
        const devices = [
            { path: "/dev/sda1", mountPoint: null, fstype: "exfat" },
            { path: "/dev/sdb1", mountPoint: "/run/media/sdb1", fstype: "ext4" },
            { path: "/dev/sdc1", mountPoint: null, fstype: "ext4" }
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

    // A superfloppy (a flash drive with a filesystem directly on the disk,
    // no partition table) has no PKNAME anywhere to resolve and no parent
    // node to look up. parseDevices already set its diskPath to its own
    // path during the walk, so ejectPlan needs nothing else to build a
    // correct unmount-then-power-off sequence for it.
    function test_eject_plan_unmounts_a_mounted_superfloppy_before_powering_off() {
        const diskPath = "/dev/sdc";
        const devices = [
            { path: diskPath, diskPath: diskPath, type: "disk", mountPoint: "/run/media/sdc" }
        ];

        const plan = Devices.ejectPlan(devices, diskPath);

        compare(plan.length, 2);
        compare(plan[0], Devices.unmountCommand(diskPath));
        compare(plan[1], Devices.powerOffCommand(diskPath));
    }
}
```

- [ ] **3** Run QtTest (`flake/apps.nix:118`'s qmltestrunner line)
      Expected: FAIL, "services/devices.js: no such file"

- [ ] **4** Write `nix/home/desktop/quickshell/qml/services/devices.js`:

```js
// Pure classification over an `lsblk -J -b` snapshot: which block devices
// are worth offering a mount button for, which are already mounted, and
// the udisksctl argv for each step. Split out of Devices.qml so
// tests/qml/tst_devices.qml can drive it against a captured fixture with no
// udev, no D-Bus and no live block device anywhere near the test.
//
// lsblk's "rm" column is the SCSI removable-media bit. A USB hard disk
// answers that bit "no", it is a fixed drive that merely lives behind a
// USB bridge, while the NVMe boot disk's EFI System Partition answers
// "hotplug" false and sits there with a filesystem and no mountpoint,
// looking exactly like a candidate to offer up for mounting. "hotplug" is
// the bit that means "arrived after boot, on a bus meant for that"; "rm" is
// a different question this file never asks. Filtering on rm would drop
// the real USB disk; filtering on fstype-without-mountpoint instead of
// hotplug would try to mount the ESP. Both are fixture-backed regression
// tests in tst_devices.qml, not a hypothetical.
.pragma library

/// lsblk emits native booleans (util-linux >= 2.37) or "0"/"1" strings,
/// same ambiguity qml/installer/disks.js guards against for the same field.
function flag(v) {
    if (typeof v === "boolean")
        return v;
    if (typeof v === "string")
        return v === "1" || v === "true";
    if (typeof v === "number")
        return v === 1;
    return false;
}

function sizeOf(v) {
    if (typeof v === "number")
        return v;
    if (typeof v === "string") {
        const n = parseInt(v.trim(), 10);
        return Number.isNaN(n) ? 0 : n;
    }
    return 0;
}

function orNull(v) {
    return v === undefined ? null : v;
}

/// Depth-first walk of one top-level lsblk entry. `diskPath` and
/// `diskHotplug` are fixed at the top-level disk and carried unchanged into
/// every descendant, because "on itself OR on its parent disk" means the
/// disk that owns the partition, not whichever node sits one level up,
/// relevant for a logical partition nested inside an extended one.
function walk(node, diskPath, diskHotplug, out) {
    const excludedType = node.type === "loop" || node.type === "rom";
    const ownHotplug = flag(node.hotplug);
    const hotplug = ownHotplug || diskHotplug;
    const fstype = orNull(node.fstype);
    const isPartition = node.type === "part";
    const isSuperfloppy = node.type === "disk" && (!Array.isArray(node.children) || node.children.length === 0);

    if (!excludedType && hotplug && fstype !== null && (isPartition || isSuperfloppy)) {
        out.push({
            name: node.name,
            path: node.path,
            diskPath: isPartition ? diskPath : node.path,
            label: orNull(node.label),
            sizeBytes: sizeOf(node.size),
            fstype: fstype,
            mountPoint: orNull(node.mountpoint),
            type: node.type,
            vendor: orNull(node.vendor),
            model: orNull(node.model),
            hotplug: ownHotplug
        });
    }

    if (Array.isArray(node.children)) {
        for (const child of node.children)
            walk(child, diskPath, diskHotplug, out);
    }
}

/// Parse `lsblk -J -b` output into a flat array of mountable devices: hotplug
/// partitions and hotplug superfloppy disks, everything else, internal
/// disks, the ESP, loop and rom devices, LVM/crypt plumbing, left out.
/// Malformed input yields an empty list rather than throwing, since this
/// runs on every udev poll and one bad read must not crash the shell.
function parseDevices(text) {
    let root;
    try {
        root = JSON.parse(text);
    } catch (e) {
        return [];
    }

    const top = root && Array.isArray(root.blockdevices) ? root.blockdevices : [];
    const out = [];
    for (const disk of top)
        walk(disk, disk.path, flag(disk.hotplug), out);
    return out;
}

/// label, else vendor+model trimmed (lsblk right-pads vendor to 8 columns),
/// else the kernel name, always something to put on the menu row.
function displayLabel(device) {
    if (device.label)
        return device.label;

    const parts = [device.vendor, device.model].map(p => (p || "").trim()).filter(p => p.length > 0);

    return parts.length > 0 ? parts.join(" ") : device.name;
}

/// Devices worth offering a mount button for: unmounted, have a filesystem,
/// and not already the target of an in-flight mount this menu started.
function mountCandidates(devices, attempted) {
    const seen = attempted || {};
    return devices.filter(d => !d.mountPoint && !!d.fstype && !Object.prototype.hasOwnProperty.call(seen, d.path));
}

/// Drop attempted-mount entries for paths that vanished from the last poll,
/// so unplugging and replugging the same stick makes it eligible again
/// instead of being remembered as permanently attempted.
function pruneAttempts(attempted, devices) {
    const present = {};
    for (const d of devices)
        present[d.path] = true;

    const pruned = {};
    for (const path of Object.keys(attempted || {})) {
        if (present[path])
            pruned[path] = attempted[path];
    }
    return pruned;
}

/// Records that transitioned from unmounted to mounted between two polls,
/// the notify-send trigger. A device absent from `previous` counts as
/// having been unmounted, so a stick that appears already-mounted still
/// fires the notification once.
function newlyMounted(previous, next) {
    const before = {};
    for (const d of previous)
        before[d.path] = d;

    return next.filter(d => {
        const prior = before[d.path];
        const wasUnmounted = !prior || !prior.mountPoint;
        return wasUnmounted && !!d.mountPoint;
    });
}

/// argv for `udisksctl mount`. The path is always its own array element,
/// see previewCommand in qml/launcher/preview.js for why that discipline
/// matters: a label or mountpoint under attacker control is legal ext4/exfat
/// metadata, and it must never be able to reach a shell as text.
function mountCommand(path) {
    return ["udisksctl", "mount", "-b", path, "--no-user-interaction"];
}

/// argv for `udisksctl unmount`. See mountCommand for the argv discipline.
function unmountCommand(path) {
    return ["udisksctl", "unmount", "-b", path, "--no-user-interaction"];
}

/// argv for `udisksctl power-off`. See mountCommand for the argv discipline.
function powerOffCommand(path) {
    return ["udisksctl", "power-off", "-b", path, "--no-user-interaction"];
}

/// The eject sequence for one disk: unmount every one of its mounted
/// devices, then power the disk off. "Its mounted devices" is partitions
/// AND the disk-as-superfloppy case parseDevices also emits, a childless
/// disk with a filesystem directly on it has diskPath equal to its own
/// path and type "disk", not "part", so filtering on type "part" alone
/// skips its unmount and hands udisksctl a power-off for a device that is
/// still mounted. Unmounting a device that was never mounted is a
/// udisksctl error the caller doesn't need, so only mounted ones get a
/// step.
function ejectPlan(devices, diskPath) {
    const mountedOnDisk = devices.filter(d => d.diskPath === diskPath && d.mountPoint);
    const plan = mountedOnDisk.map(d => unmountCommand(d.path));
    plan.push(powerOffCommand(diskPath));
    return plan;
}
```

- [ ] **5** Run QtTest again
      Expected: PASS, 7/7

- [ ] **6** `nix run .#nix-lint`
      Expected: green

- [ ] **7** `git add tests/qml/fixtures/lsblk-devices.json nix/home/desktop/quickshell/qml/services/devices.js tests/qml/tst_devices.qml`
      `git commit -m "feat: classify block devices for automount"`

---

### Task 2: `Devices.qml`, the singleton, wired live through the bar pill

**Files:**
- Create: `nix/home/desktop/quickshell/qml/services/qmldir`
- Create: `nix/home/desktop/quickshell/qml/services/Devices.qml`
- Create: `nix/home/desktop/quickshell/qml/bar/Drives.qml`
- Modify: `nix/home/desktop/quickshell/qml/bar/Bar.qml`

**Produces:** `Devices.devices` (readonly, `devices.js`'s `parseDevices()`
shape narrowed to `mountPoint !== null`: `{name, path, diskPath, label,
sizeBytes, fstype, mountPoint, type, vendor, model, hotplug}[]`),
`Devices.rescan()`, `Devices.eject(path)`, `signal requestOpen(string
path)`. `bar/Drives.qml` is what forces the singleton alive at shell
startup and is this task's only way to prove any of it runs, since nothing
else in the tree reads `Devices` yet.

- [ ] **1** Write `nix/home/desktop/quickshell/qml/services/qmldir`:

```
singleton Devices 1.0 Devices.qml
```

- [ ] **2** Write `nix/home/desktop/quickshell/qml/services/Devices.qml`:

```qml
// The devices service: watches udev for block-device hotplug, automounts
// anything that qualifies, and exposes the result to every surface that
// shows a drive: the bar pill, the launcher's device rows and (Plan 1)
// directory hits, and the file manager's sidebar.
//
// Same shape as qml/monitors/Watcher.qml: a persistent Process watching a
// live event stream, a Timer debouncing a burst of events into one rescan,
// and the rescan reading a fresh JSON snapshot rather than reconstructing
// state from the event stream's own text. Unplugging a hub fires several
// udev lines at once, the same way unplugging a monitor dock fires several
// Hyprland events at once.
//
// No explicit instantiation anywhere: this is a pragma Singleton, the same
// shape as Theme.qml, and it depends on the same guarantee Theme.qml's own
// live FileView already relies on, the first read of a property here
// constructs it. bar/Drives.qml reads `Devices.devices` in a `visible`
// binding, and Bar.qml is built for every screen the instant shell.qml
// loads, so this, and the persistent udevadm Process inside it, is alive
// before the first frame is on screen.
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "devices.js" as DevicesMath

Singleton {
    id: root

    property var flat: []
    property var attempted: ({})

    readonly property var devices: root.flat.filter(d => d.mountPoint !== null)

    signal requestOpen(string path)

    readonly property string lsblkColumns: "NAME,PATH,LABEL,SIZE,FSTYPE,MOUNTPOINT,HOTPLUG,TYPE,VENDOR,MODEL"

    function rescan(): void {
        scanProc.running = false;
        scanProc.running = true;
    }

    function eject(path: string): void {
        const device = root.flat.find(d => d.path === path);
        const diskPath = device ? device.diskPath : path;
        const controller = ejectController.createObject(root, { plan: DevicesMath.ejectPlan(root.flat, diskPath) });
        controller.start();
    }

    function applyScan(json: string): void {
        root.flat = DevicesMath.parseDevices(json);
        root.attempted = DevicesMath.pruneAttempts(root.attempted, root.flat);
        root.mountPending();
    }

    function mountPending(): void {
        for (const device of DevicesMath.mountCandidates(root.flat, root.attempted)) {
            root.attempted = Object.assign({}, root.attempted, { [device.path]: true });
            const runner = mountRunner.createObject(root, { command: DevicesMath.mountCommand(device.path) });
            runner.running = true;
        }
    }

    IpcHandler {
        target: "devices"

        function rescan(): void {
            root.rescan();
        }
    }

    // The one live udev read: any line on the block subsystem means the
    // topology might have changed. The trigger does not try to parse which
    // device or which action, that is what the rescan below is for.
    Process {
        id: udevWatch

        running: true
        command: ["udevadm", "monitor", "--udev", "--subsystem-match=block"]

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: debounce.restart()
        }
    }

    Timer {
        id: debounce

        interval: 300
        onTriggered: root.rescan()
    }

    Component.onCompleted: root.rescan()

    Process {
        id: scanProc

        command: ["lsblk", "-J", "-b", "-o", root.lsblkColumns]

        stdout: StdioCollector {
            onStreamFinished: root.applyScan(this.text)
        }
    }

    Component {
        id: mountRunner

        Process {
            // qmllint disable signal-handler-parameters
            onExited: (exitCode, exitStatus) => {
                root.rescan();
                destroy();
            }
            // qmllint enable signal-handler-parameters
        }
    }

    // ejectPlan(flat, diskPath) is a list of argv steps, not a fixed
    // unmount-then-power-off pair: a disk with more than one mounted
    // partition needs one unmount per partition ahead of the single
    // power-off. ctrl walks that list one Process at a time instead of
    // hardcoding two.
    Component {
        id: ejectController

        Item {
            id: ctrl

            property var plan: []
            property int step: 0

            function start(): void {
                ctrl.runStep();
            }

            function runStep(): void {
                if (ctrl.step >= ctrl.plan.length) {
                    root.rescan();
                    ctrl.destroy();
                    return;
                }

                const runner = ejectStep.createObject(ctrl, { command: ctrl.plan[ctrl.step] });
                runner.running = true;
            }

            Component {
                id: ejectStep

                Process {
                    // qmllint disable signal-handler-parameters
                    onExited: (exitCode, exitStatus) => {
                        ctrl.step += 1;
                        destroy();
                        ctrl.runStep();
                    }
                    // qmllint enable signal-handler-parameters
                }
            }
        }
    }
}
```

`mountPending()`'s three orderings each guard something a slightly different
sketch would get wrong.

`applyScan()` runs `pruneAttempts` before `mountPending` ever calls
`mountCandidates`, not after: `attempted` has to already be unplug-accurate
before it is used to decide what still needs offering, or a device that was
unplugged and replugged under the same path would stay wrongly excluded by
an attempt entry this scan can no longer justify.

`mountPending()` marks `device.path` attempted before `runner.running =
true`, never after. A burst of udev lines from one hotplug event can
debounce into more than one rescan tick, and `onExited` itself triggers
another rescan; queuing the mount first and marking it attempted afterward
would leave a window where a second, concurrent `mountPending()` call sees
the same still-unmounted device and queues a second `udisksctl mount`
racing the first. Marking first closes that window before the `Process`
object it guards even exists.

`attempted` clears one entry only when its path drops out of the next
`lsblk` scan entirely, which is what unplugging means. A device that stays
plugged in and merely fails to mount stays marked, so a corrupt or
unsupported filesystem is offered once and then left alone rather than
retried on every debounced rescan forever. The same rule keeps a deliberate
`udisksctl unmount` run from outside this shell from being treated as "try
again": the unmounted device is still present in the next scan under the
same path, so it stays in `attempted` and is not silently re-mounted out
from under whoever unmounted it on purpose.

- [ ] **3** Write `nix/home/desktop/quickshell/qml/bar/Drives.qml`:

```qml
// The removable-media pill: a live count of currently-mounted devices,
// hidden entirely when nothing is plugged in, the same "hide when there's
// nothing to say" rule Battery.qml already follows for a desktop with no
// battery.
//
// The click handler runs `qs ipc call files toggle` unconditionally, ahead
// of the `files` IPC target existing at all (that lands in Plan 1). The
// call fails quietly against an unregistered target today and starts
// opening the file manager the moment Plan 1 lands, with no further edit
// to this file.
import QtQuick
import Quickshell
import "../services"
import ".."

Pill {
    id: root

    interactive: true
    visible: Devices.devices.length > 0

    onClicked: Quickshell.execDetached(["qs", "ipc", "call", "files", "toggle"])

    Text {
        text: `💾 ${Devices.devices.length}`
        color: Theme.bg

        font.family: Theme.fontUi
        font.pixelSize: Theme.barFontSize
        font.bold: true
    }
}
```

- [ ] **4** In `nix/home/desktop/quickshell/qml/bar/Bar.qml`, add `Drives {}` to the
      right-side `Row`, between `Network {}` and `Battery {}`

- [ ] **5** `nix build .#quickshell-config && cat result/services/qmldir`
      Expected: `singleton Devices 1.0 Devices.qml`

- [ ] **6** `nix run .#nix-lint`
      Expected: green. This is what proves `import "../services"` resolves
      through the hand-written `qmldir` with no `tree.nix` change; if it
      does not, fall back to teaching `tree.nix` to write this `qmldir` the
      way it writes the root one (see the spec's Decisions section)

- [ ] **7** Reload the shell (`qs kill` then re-launch, or a fresh Hyprland
      session) and unplug, then replug, the real attached WD 2TB USB disk
      Expected: `lsblk -J -b -o NAME,MOUNTPOINT` shows `sda1` with a
      non-null `mountpoint` within a couple of seconds of replugging, and
      the bar pill on every monitor reads `💾 1`

- [ ] **8** `qs ipc call devices rescan`
      Expected: exits 0, proof the `devices` IPC target is registered,
      which only happens because step 7 already forced the singleton alive

- [ ] **9** `git add nix/home/desktop/quickshell/qml/services/qmldir nix/home/desktop/quickshell/qml/services/Devices.qml nix/home/desktop/quickshell/qml/bar/Drives.qml nix/home/desktop/quickshell/qml/bar/Bar.qml`
      `git commit -m "feat: automount hotplugged block devices"`

---

### Task 3: The mount toast

**Files:** Modify `nix/home/desktop/quickshell/qml/services/Devices.qml`.
**Produces:** a `notify-send` toast the moment a device transitions from
absent-or-unmounted to mounted.

- [ ] **1** Replace `applyScan` and add `toast`:

```qml
    property var previousDevices: []

    function applyScan(json: string): void {
        root.flat = DevicesMath.parseDevices(json);
        root.attempted = DevicesMath.pruneAttempts(root.attempted, root.flat);

        for (const device of DevicesMath.newlyMounted(root.previousDevices, root.devices))
            root.toast(device);
        root.previousDevices = root.devices;

        root.mountPending();
    }

    function toast(device: var): void {
        Quickshell.execDetached(["notify-send", "--app-name=dots-shell", "--icon=drive-removable-media", "Drive mounted", `${device.label} at ${device.mountPoint}`]);
    }
```

`applyScan` no longer hand-rolls the mounted-path diff `newlyMounted`
already exists to do: `devices.js` exports exactly this transition check,
so the toast trigger reuses it instead of tracking a second, parallel
`previousMountedPaths` array that could drift out of sync with `attempted`
or `devices` itself.

`toast()`'s last argv element interpolates `device.label` and
`device.mountPoint` into one string, unlike `mountCommand`, `unmountCommand`
and `powerOffCommand`, which always keep a path as its own element. That is
not the same rule broken twice. `notify-send`, like every libnotify client,
takes summary and body as two positional arguments, so the body is one
display string by the tool's own API, not a shell string built by
concatenation. There is no argv boundary here for a label or a mountpoint
to cross, and so no injection surface the one-path-per-element rule exists
to close.

- [ ] **2** `nix run .#nix-lint`
      Expected: green

- [ ] **3** In one terminal: `dbus-monitor --session "interface='org.freedesktop.Notifications',member='Notify'" &`.
      Unplug and replug the real USB disk
      Expected: the capture shows a `Notify` call whose string arguments
      include `Drive mounted` and the mountpoint; the toast is also visible
      on screen, rendered by `qml/notifications/Notifications.qml` (`notify-send` talks to the same `org.freedesktop.Notifications` name that
      server already owns)

- [ ] **4** `git add nix/home/desktop/quickshell/qml/services/Devices.qml`
      `git commit -m "feat: toast when a device automounts"`

---

### Task 4: Launcher device rows

**Files:**
- Modify: `nix/home/desktop/quickshell/qml/launcher/Providers.qml`
- Modify: `nix/home/desktop/quickshell/qml/launcher/Launcher.qml`

**Produces:** `Providers.deviceRows(text)`, spliced into the launcher's
ambient result set.

- [ ] **1** In `Providers.qml`, add the import alongside the existing ones:

```qml
import "../services"
```

- [ ] **2** Add, near `systemRows`:

```qml
    function deviceRows(text: string): var {
        const rows = [];

        for (const device of Devices.devices) {
            if (!root.matches(device.label, text))
                continue;

            rows.push({
                title: device.label,
                subtitle: device.mountPoint,
                icon: "",
                accessory: "open",
                run: () => Devices.requestOpen(device.mountPoint)
            });
        }

        return rows;
    }
```

- [ ] **3** In `Launcher.qml`'s `results` property, splice `deviceRows`
      into the ambient chain, after `systemRows`:

```qml
        const rows = providers.applicationRows(needle).concat(providers.systemRows(needle)).concat(providers.deviceRows(needle)).concat(providers.quicklinkRows(needle)).concat(providers.snippetRows(needle)).concat(providers.fileRows(needle));
```

- [ ] **4** `nix run .#nix-lint`
      Expected: green

- [ ] **5** With the real USB disk still mounted from Task 2, open the
      launcher (SUPER+Space) and type a substring of its label or model
      (e.g. "WD")
      Expected: a row appears with accessory "open"; activating it currently
      does nothing visible (`Devices.requestOpen` has no listener until
      Plan 1's `Files.qml` connects to it), that is the expected,
      forward-compatible state this task leaves behind, not a bug

- [ ] **6** `git add nix/home/desktop/quickshell/qml/launcher/Providers.qml nix/home/desktop/quickshell/qml/launcher/Launcher.qml`
      `git commit -m "feat: surface mounted devices in the launcher"`
