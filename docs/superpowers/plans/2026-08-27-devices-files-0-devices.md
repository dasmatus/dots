# Devices & Files 0: Devices Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use
> superpowers:subagent-driven-development or superpowers:executing-plans.

**Goal:** A plugged-in USB/SD device automounts with no daemon but the shell
itself, and becomes visible on the bar and in the launcher. No file manager
yet — that is Plan 1.
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
  without `-b` — this machine's locale prints `"1,8T"` with a comma.
- `udisksctl`'s stdout is read for nothing. Only its exit code, followed by
  a fresh `lsblk` rescan to learn the real resulting state.
- The automount filter is `hotplug === true && fstype !== null &&
  mountpoint === null`. Never `rm` (a USB hard disk reports `rm: false`),
  never "has an fstype and isn't mounted" alone (the EFI System Partition
  has exactly that shape with `hotplug: false`).
- `qmllint --max-warnings 0` over the whole tree, unchanged gate
  (`nix run .#nix-lint`).
- `Devices` is a `pragma Singleton`. No `Devices {}` line is ever added to
  `shell.qml` — the point of Task 2 is proving the singleton comes alive
  from being *read*, the same way `Theme.qml` already does.

---

### Task 1: `devices.js` — pure classification, TDD against the real fixture

**Files:**
- Create: `tests/qml/fixtures/lsblk-devices.json`
- Create: `nix/home/quickshell/qml/services/devices.js`
- Create: `tests/qml/tst_devices.qml`

**Produces:** `devices.js` exporting `flatten(json)`, `candidates(flat)`,
`mounted(flat)`, `displayLabel(device)`, `parentPath(flat, path)`. Reuses
`qml/installer/disks.js`'s `parentDisk(path)` as `parentPath`'s fallback
when a device carries no `PKNAME` — one heuristic, not two.

- [ ] **1** `cp .superpowers/sdd/rosy-zooming-lemon/lsblk-fixture.json tests/qml/fixtures/lsblk-devices.json`
      Expected: `git status` shows the new file under `tests/qml/fixtures/`

- [ ] **2** Write `tests/qml/tst_devices.qml`:

```qml
// Proves the ESP-exclusion rule end to end: a filter of "has an fstype and
// isn't mounted" would try to mount /dev/nvme0n1p1, the EFI System
// Partition. Only `hotplug` tells it apart from /dev/sda1, the real USB
// disk, and this fixture is a genuine `lsblk -J -b` capture carrying both
// side by side.
//
// Reading the fixture needs QML_XHR_ALLOW_FILE_READ=1 (flake/apps.nix
// already sets it on the qmltestrunner invocation — see tst_installer.qml).
import QtQuick
import QtTest
import "../../nix/home/quickshell/qml/services/devices.js" as Devices

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

    function test_flatten_walks_every_nesting_level() {
        const names = Devices.flatten(fixtureJson).map(d => d.name);

        // loop0 (top level), sda1 (one level down), cryptroot (four levels
        // deep under nvme0n1p2 -> LVM -> LUKS) — proof this walks children
        // recursively rather than only reading blockdevices[*].
        verify(names.includes("loop0"));
        verify(names.includes("sda1"));
        verify(names.includes("cryptroot"));
    }

    function test_candidates_excludes_the_esp() {
        const flat = Devices.flatten(fixtureJson);
        const paths = Devices.candidates(flat).map(d => d.path);

        verify(!paths.includes("/dev/nvme0n1p1"), "must not offer to mount the ESP, got " + JSON.stringify(paths));
    }

    function test_candidates_includes_the_real_usb_partition() {
        const flat = Devices.flatten(fixtureJson);
        const paths = Devices.candidates(flat).map(d => d.path);

        verify(paths.includes("/dev/sda1"));
    }

    function test_candidates_excludes_the_whole_disk_with_no_filesystem_of_its_own() {
        const flat = Devices.flatten(fixtureJson);
        const paths = Devices.candidates(flat).map(d => d.path);

        // sda has fstype:null; only its child sda1 carries one.
        verify(!paths.includes("/dev/sda"));
    }

    function test_mounted_shapes_the_public_device_list() {
        // The fixture's sda1 is unmounted; this stands in for what a
        // rescan sees once udisksctl mount has actually run.
        const flat = Devices.flatten(fixtureJson).map(d => d.path === "/dev/sda1" ? Object.assign({}, d, { mountpoint: "/run/media/matus/BACKUP" }) : d);
        const devices = Devices.mounted(flat);

        compare(devices.length, 1);
        compare(devices[0].path, "/dev/sda1");
        compare(devices[0].mountpoint, "/run/media/matus/BACKUP");
    }

    function test_displaylabel_falls_back_from_label_to_model_to_name() {
        compare(Devices.displayLabel({ name: "sda1", label: "BACKUP", model: "WDC WD20SDZW" }), "BACKUP");
        compare(Devices.displayLabel({ name: "sda1", label: null, model: "WDC WD20SDZW-59Z3CS0" }), "WDC WD20SDZW-59Z3CS0");
        compare(Devices.displayLabel({ name: "sda1", label: null, model: null }), "sda1");
    }

    function test_parentpath_prefers_pkname() {
        const flat = [
            { name: "sda", path: "/dev/sda", pkname: null },
            { name: "sda1", path: "/dev/sda1", pkname: "sda" }
        ];

        compare(Devices.parentPath(flat, "/dev/sda1"), "/dev/sda");
    }

    // A whole disk formatted directly has no partition and so no PKNAME
    // anywhere in the scan — eject() must still resolve to a real device.
    function test_parentpath_falls_back_to_the_devices_own_path() {
        const flat = [
            { name: "sda", path: "/dev/sda", pkname: null }
        ];

        compare(Devices.parentPath(flat, "/dev/sda"), "/dev/sda");
    }
}
```

- [ ] **3** Run QtTest (`flake/apps.nix:118`'s qmltestrunner line)
      Expected: FAIL, "services/devices.js: no such file"

- [ ] **4** Write `nix/home/quickshell/qml/services/devices.js`:

```js
// Pure classification over an `lsblk -J -b -o
// NAME,PATH,LABEL,SIZE,FSTYPE,MOUNTPOINT,RM,HOTPLUG,TYPE,VENDOR,MODEL,PKNAME`
// snapshot. Split out of Devices.qml so tests/qml/tst_devices.qml can drive
// it against a captured fixture with no udev, no D-Bus and no live block
// device anywhere near the test.
//
// `hotplug`, never `rm`: the USB hard disk this was written against
// reports rm:false, so filtering on rm would silently ignore it. `hotplug`,
// never "has an fstype and isn't mounted" either: the EFI System Partition
// has exactly that shape with hotplug:false, and that filter would try to
// mount the ESP on every scan.
.pragma library
.import "../installer/disks.js" as Disks

function flatten(json) {
    const root = JSON.parse(json);
    const out = [];

    function walk(nodes) {
        for (const node of nodes) {
            const copy = {};
            for (const key in node) {
                if (key !== "children")
                    copy[key] = node[key];
            }
            out.push(copy);
            walk(node.children ?? []);
        }
    }

    walk(root.blockdevices ?? []);
    return out;
}

function candidates(flat) {
    return flat.filter(d => d.hotplug === true && d.fstype !== null && d.mountpoint === null);
}

function mounted(flat) {
    return flat.filter(d => d.hotplug === true && d.fstype !== null && d.mountpoint !== null).map(d => ({
                path: d.path,
                label: displayLabel(d),
                mountpoint: d.mountpoint,
                fstype: d.fstype,
                size: d.size
            }));
}

function displayLabel(device) {
    if (device.label)
        return device.label;

    if (device.model && device.model.trim() !== "")
        return device.model.trim();

    return device.name;
}

// Resolves the whole disk behind a partition, for eject()'s udisksctl
// power-off target. PKNAME is the authoritative column when the scan
// carried it; Disks.parentDisk's suffix-stripping heuristic — already
// proven by the installer's own disk autodetection — is the fallback, and
// it hands back a whole disk's own path unchanged when there is no
// partition suffix to strip, which is also the right answer here.
function parentPath(flat, path) {
    const device = flat.find(d => d.path === path);
    if (!device)
        return path;

    if (device.pkname) {
        const parent = flat.find(d => d.name === device.pkname);
        if (parent)
            return parent.path;
    }

    return Disks.parentDisk(path);
}
```

- [ ] **5** Run QtTest again
      Expected: PASS, 8/8

- [ ] **6** `nix run .#nix-lint`
      Expected: green

- [ ] **7** `git add tests/qml/fixtures/lsblk-devices.json nix/home/quickshell/qml/services/devices.js tests/qml/tst_devices.qml`
      `git commit -m "feat: classify block devices for automount"`

---

### Task 2: `Devices.qml` — the singleton, wired live through the bar pill

**Files:**
- Create: `nix/home/quickshell/qml/services/qmldir`
- Create: `nix/home/quickshell/qml/services/Devices.qml`
- Create: `nix/home/quickshell/qml/bar/Drives.qml`
- Modify: `nix/home/quickshell/qml/bar/Bar.qml`

**Produces:** `Devices.devices` (readonly, `{path, label, mountpoint,
fstype, size}[]`), `Devices.rescan()`, `Devices.eject(path)`, `signal
requestOpen(string path)`. `bar/Drives.qml` is what forces the singleton
alive at shell startup and is this task's only way to prove any of it runs,
since nothing else in the tree reads `Devices` yet.

- [ ] **1** Write `nix/home/quickshell/qml/services/qmldir`:

```
singleton Devices 1.0 Devices.qml
```

- [ ] **2** Write `nix/home/quickshell/qml/services/Devices.qml`:

```qml
// The devices service: watches udev for block-device hotplug, automounts
// anything that qualifies, and exposes the result to every surface that
// shows a drive — the bar pill, the launcher's device rows and (Plan 1)
// directory hits, and the file manager's sidebar.
//
// Same shape as qml/monitors/Watcher.qml: a persistent Process watching a
// live event stream, a Timer debouncing a burst of events into one rescan,
// and the rescan reading a fresh JSON snapshot rather than reconstructing
// state from the event stream's own text — unplugging a hub fires several
// udev lines at once, the same way unplugging a monitor dock fires several
// Hyprland events at once.
//
// No explicit instantiation anywhere: this is a pragma Singleton, the same
// shape as Theme.qml, and it depends on the same guarantee Theme.qml's own
// live FileView already relies on — the first read of a property here
// constructs it. bar/Drives.qml reads `Devices.devices` in a `visible`
// binding, and Bar.qml is built for every screen the instant shell.qml
// loads, so this — and the persistent udevadm Process inside it — is alive
// before the first frame is on screen.
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "devices.js" as DevicesMath

Singleton {
    id: root

    property var flat: []

    readonly property var devices: DevicesMath.mounted(root.flat)

    signal requestOpen(string path)

    readonly property string lsblkColumns: "NAME,PATH,LABEL,SIZE,FSTYPE,MOUNTPOINT,RM,HOTPLUG,TYPE,VENDOR,MODEL,PKNAME"

    function rescan(): void {
        scanProc.running = false;
        scanProc.running = true;
    }

    function eject(path: string): void {
        const controller = ejectController.createObject(root, { path: path });
        controller.start();
    }

    function applyScan(json: string): void {
        root.flat = DevicesMath.flatten(json);
        root.mountPending();
    }

    function mountPending(): void {
        for (const device of DevicesMath.candidates(root.flat)) {
            const runner = mountRunner.createObject(root, { command: ["udisksctl", "mount", "-b", device.path] });
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
    // device or which action — that is what the rescan below is for.
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

    Component {
        id: ejectController

        Item {
            id: ctrl

            property string path: ""
            readonly property string diskPath: DevicesMath.parentPath(root.flat, ctrl.path)

            function start(): void {
                unmount.running = true;
            }

            Process {
                id: unmount

                command: ["udisksctl", "unmount", "-b", ctrl.path]

                // qmllint disable signal-handler-parameters
                onExited: (exitCode, exitStatus) => powerOff.running = true
                // qmllint enable signal-handler-parameters
            }

            Process {
                id: powerOff

                command: ["udisksctl", "power-off", "-b", ctrl.diskPath]

                // qmllint disable signal-handler-parameters
                onExited: (exitCode, exitStatus) => {
                    root.rescan();
                    ctrl.destroy();
                }
                // qmllint enable signal-handler-parameters
            }
        }
    }
}
```

- [ ] **3** Write `nix/home/quickshell/qml/bar/Drives.qml`:

```qml
// The removable-media pill: a live count of currently-mounted devices,
// hidden entirely when nothing is plugged in — the same "hide when there's
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

- [ ] **4** In `nix/home/quickshell/qml/bar/Bar.qml`, add `Drives {}` to the
      right-side `Row`, between `Network {}` and `Battery {}`

- [ ] **5** `nix build .#quickshell-config && cat result/services/qmldir`
      Expected: `singleton Devices 1.0 Devices.qml`

- [ ] **6** `nix run .#nix-lint`
      Expected: green — this is what proves `import "../services"` resolves
      through the hand-written `qmldir` with no `tree.nix` change; if it
      does not, fall back to teaching `tree.nix` to write this `qmldir` the
      way it writes the root one (see the spec's Decisions section)

- [ ] **7** Reload the shell (`qs kill` then re-launch, or a fresh Hyprland
      session) and unplug, then replug, the real attached WD 2TB USB disk
      Expected: `lsblk -J -b -o NAME,MOUNTPOINT` shows `sda1` with a
      non-null `mountpoint` within a couple of seconds of replugging, and
      the bar pill on every monitor reads `💾 1`

- [ ] **8** `qs ipc call devices rescan`
      Expected: exits 0 — proof the `devices` IPC target is registered,
      which only happens because step 7 already forced the singleton alive

- [ ] **9** `git add nix/home/quickshell/qml/services/qmldir nix/home/quickshell/qml/services/Devices.qml nix/home/quickshell/qml/bar/Drives.qml nix/home/quickshell/qml/bar/Bar.qml`
      `git commit -m "feat: automount hotplugged block devices"`

---

### Task 3: The mount toast

**Files:** Modify `nix/home/quickshell/qml/services/Devices.qml`.
**Produces:** a `notify-send` toast the moment a device transitions from
absent-or-unmounted to mounted.

- [ ] **1** Replace `applyScan` and add `toast`:

```qml
    property var previousMountedPaths: []

    function applyScan(json: string): void {
        root.flat = DevicesMath.flatten(json);

        const nextPaths = root.devices.map(d => d.path);
        for (const device of root.devices) {
            if (!root.previousMountedPaths.includes(device.path))
                root.toast(device);
        }
        root.previousMountedPaths = nextPaths;

        root.mountPending();
    }

    function toast(device: var): void {
        Quickshell.execDetached(["notify-send", "--app-name=dots-shell", "--icon=drive-removable-media", "Drive mounted", `${device.label} at ${device.mountpoint}`]);
    }
```

- [ ] **2** `nix run .#nix-lint`
      Expected: green

- [ ] **3** In one terminal: `dbus-monitor --session "interface='org.freedesktop.Notifications',member='Notify'" &`.
      Unplug and replug the real USB disk
      Expected: the capture shows a `Notify` call whose string arguments
      include `Drive mounted` and the mountpoint; the toast is also visible
      on screen, rendered by `qml/notifications/Notifications.qml` (`notify-send` talks to the same `org.freedesktop.Notifications` name that
      server already owns)

- [ ] **4** `git add nix/home/quickshell/qml/services/Devices.qml`
      `git commit -m "feat: toast when a device automounts"`

---

### Task 4: Launcher device rows

**Files:**
- Modify: `nix/home/quickshell/qml/launcher/Providers.qml`
- Modify: `nix/home/quickshell/qml/launcher/Launcher.qml`

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
                subtitle: device.mountpoint,
                icon: "",
                accessory: "open",
                run: () => Devices.requestOpen(device.mountpoint)
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
      Plan 1's `Files.qml` connects to it) — that is the expected,
      forward-compatible state this task leaves behind, not a bug

- [ ] **6** `git add nix/home/quickshell/qml/launcher/Providers.qml nix/home/quickshell/qml/launcher/Launcher.qml`
      `git commit -m "feat: surface mounted devices in the launcher"`
