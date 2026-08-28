// The devices service: watches udev for block-device hotplug, automounts
// anything that qualifies, and is the one thing every drive-aware surface
// reads from, the bar pill, the launcher's device rows, and (later) the
// file manager's sidebar.
//
// pragma Singleton, no `Devices {}` line anywhere in shell.qml: this comes
// alive the same way Theme.qml already does, on its first property read,
// not on explicit instantiation. The bar pill is what forces that read once
// it exists; until then this file can sit here fully wired and genuinely
// inert.
//
// Shaped like qml/monitors/Watcher.qml: a persistent Process tailing a live
// event stream, a Timer folding a burst of events into one rescan, and the
// rescan re-reading a fresh JSON snapshot rather than trying to reconstruct
// state from the event stream's own text. Unplugging a hub fires a dozen
// udev lines in the same instant unplugging a dock fires a dozen Hyprland
// events, and both files answer it the same way, debounce, then ask the
// kernel again from scratch.
//
// THE LOOP GUARD. Mounting a device is itself a udev event: udisksctl mount
// changes the block device's state, udevadm prints a line, the debounce
// timer fires, refresh() runs again. Nothing about that chain terminates on
// its own, so `attempted` is the one thing standing between a single
// plugged-in stick and udisksctl running in an unbounded loop against it.
// Every refresh prunes `attempted` first, a path only leaves that set by
// vanishing from lsblk entirely, which means it was unplugged, computes
// candidates against the pruned result, and marks each candidate attempted
// in the same call that queues its mount, never after, because a second
// refresh can land before the first mount's own onExited does, and a
// same-call mark-then-queue is what keeps that second refresh from seeing
// the device as still eligible. Only once every candidate this scan found
// is already marked does the parsed list become the published `devices`.
// A device that stays plugged in and simply fails to mount stays marked and
// is left alone rather than retried on every debounced tick forever; a
// device unmounted from outside this shell on purpose stays marked for the
// same reason, since it never left lsblk, so a deliberate `udisksctl
// unmount` is never silently undone. eject() extends the same guard to
// every device it is about to unmount, not only the one whose eject button
// was clicked, since the unmount itself is a udev event too and would
// otherwise re-offer a sibling partition on the same disk as a mount
// candidate in the gap between eject's own queued steps.
//
// The udisksctl calls themselves queue through one reused Process in
// Settings.qml's writer shape, a pending list of argv, next() driven from
// onExited rather than a chain of ephemeral Process objects, so a mount
// queued mid-eject waits its turn instead of racing udisksctl against
// itself. Only the exit code is ever read. udisksctl's own stdout is
// deliberately never parsed, on this machine it prints German, and every
// other locale prints something else; a fresh lsblk rescan is the only
// truth this file trusts about what actually happened.
//
// The mount toast carries x-dunst-stack-tag (Notifications.qml declares
// extraHints for exactly this), so a drive that mounts, drops and mounts
// again inside one debounce window replaces its own card instead of
// stacking a second one under it.
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "devices.js" as DevicesMath

Singleton {
    id: root

    // Every hotplug partition and hotplug superfloppy disk devices.js's
    // parseDevices() found, mounted or not. Internal: mountCandidates() and
    // ejectPlan() both need the unmounted entries too, which is why this is
    // not what other surfaces read.
    property var flat: []

    // Paths this singleton has already queued a mount or an eject step for
    // and does not want offered again until they vanish from lsblk. Keyed
    // by path, valued true, an object rather than an array so pruneAttempts
    // and the mark-before-queue calls below can all work in O(1).
    property var attempted: ({})

    // The published `devices` from the previous scan, kept only so
    // newlyMounted() has something to diff the current scan against.
    property var previousDevices: []

    // What every other surface actually reads: `flat` narrowed to devices
    // that are currently mounted, since an unmounted candidate is this
    // file's own business, not the bar pill's or the launcher's.
    readonly property var devices: root.flat.filter(d => d.mountPoint !== null)

    // Consumed in a later part by the file manager; the launcher's device
    // rows and (later) directory hits and the sidebar all emit this rather
    // than each owning their own notion of "open this path".
    signal requestOpen(string path)

    function refresh(): void {
        scanProc.running = false;
        scanProc.running = true;
    }

    // Marks `path` attempted and queues its mount in the same call, so a
    // caller never has one without the other. applyScan's automount loop
    // below calls this once per candidate for exactly that reason.
    function mount(path: string): void {
        root.attempted = Object.assign({}, root.attempted, {
            [path]: true
        });
        root.queueAction(DevicesMath.mountCommand(path));
    }

    // Unmounts every device still mounted on diskPath, then powers it off,
    // via ejectPlan(). Every device that plan is about to unmount is marked
    // attempted first, not only devPath, the one whose eject affordance was
    // actually clicked, because a disk with more than one mounted partition
    // has udisksctl unmount fire a real udev event per partition, and a
    // rescan landing between two of eject's own queued steps must not see
    // an already-unmounted sibling as a fresh mount candidate.
    function eject(devPath: string, diskPath: string): void {
        const marks = Object.assign({}, root.attempted, {
            [devPath]: true
        });
        for (const device of root.flat) {
            if (device.diskPath === diskPath && device.mountPoint)
                marks[device.path] = true;
        }
        root.attempted = marks;

        for (const step of DevicesMath.ejectPlan(root.flat, diskPath))
            root.queueAction(step);
    }

    // Appends to the shared udisksctl queue and kicks it if it was idle.
    // Settings.qml's writer can simply overwrite `pending` because save()
    // is one discrete user action; this queue instead gets refilled by
    // mount() and eject() while a previous batch may still be draining, so
    // an append-and-kick-if-idle is the only safe way to reuse that shape.
    function queueAction(command: var): void {
        action.pending = action.pending.concat([command]);
        if (!action.running)
            action.next();
    }

    function applyScan(text: string): void {
        const parsed = DevicesMath.parseDevices(text);

        root.attempted = DevicesMath.pruneAttempts(root.attempted, parsed);

        for (const candidate of DevicesMath.mountCandidates(parsed, root.attempted))
            root.mount(candidate.path);

        root.flat = parsed;

        for (const device of DevicesMath.newlyMounted(root.previousDevices, root.devices))
            root.toast(device);
        root.previousDevices = root.devices;
    }

    function toast(device: var): void {
        const label = DevicesMath.displayLabel(device);

        Quickshell.execDetached(["notify-send", "--app-name=dots-shell", "--icon=drive-removable-media", "--hint=string:x-dunst-stack-tag:device-" + device.name, "Drive mounted", label + " at " + device.mountPoint]);
    }

    IpcHandler {
        target: "devices"

        function refresh(): void {
            root.refresh();
        }
    }

    // The one live udev read: any line on the block subsystem means the
    // topology might have changed. udevadm's own startup banner is a few
    // lines of greeting text before it ever prints an event, and each of
    // those lines still restarts the debounce below, which is what gives
    // this singleton its first refresh without a separate
    // Component.onCompleted call.
    Process {
        id: udevWatch

        running: true
        command: ["udevadm", "monitor", "--udev", "--subsystem-match=block"]

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: debounce.restart()
        }

        // Process.exited carries a QProcess::ExitStatus second argument
        // whose type Quickshell does not export, the same gap
        // Settings.qml's writer works around for the same reason.
        // qmllint disable signal-handler-parameters
        onExited: (exitCode, exitStatus) => udevRestart.restart()
        // qmllint enable signal-handler-parameters
    }

    // udevadm dying, killed, crashed, binary briefly missing during an
    // update, must not leave this singleton blind to every future hotplug
    // for the rest of the session. A short delay before respawning rather
    // than an immediate restart keeps a persistently broken udevadm from
    // burning CPU in a tight spawn loop.
    Timer {
        id: udevRestart

        interval: 1000

        onTriggered: {
            udevWatch.running = false;
            udevWatch.running = true;
        }
    }

    // Folds a burst of udev lines, unplugging a hub fires several, into one
    // rescan, the same 300-400ms window Watcher.qml's own debounce uses for
    // Hyprland's event bursts.
    Timer {
        id: debounce

        interval: 400
        onTriggered: root.refresh()
    }

    // -b is not optional: this machine's locale prints "1,8T" with a comma
    // otherwise, and devices.js's sizeOf() would parse that comma as a
    // decimal point and return a number a thousand times too small.
    Process {
        id: scanProc

        command: ["lsblk", "-J", "-b", "-o", "NAME,PATH,LABEL,SIZE,FSTYPE,MOUNTPOINT,RM,HOTPLUG,TYPE,VENDOR,MODEL"]

        stdout: StdioCollector {
            onStreamFinished: root.applyScan(this.text)
        }
    }

    // The udisksctl action queue. One Process, reused, `pending` a plain
    // argv list rather than the field-key list Settings.qml's writer holds,
    // next() runs whatever is at the front and re-arms itself from
    // onExited; refresh() runs once the queue is empty, since only a fresh
    // lsblk read, never udisksctl's own translated stdout, is trusted for
    // what the actions actually did.
    Process {
        id: action

        property var pending: []

        function next(): void {
            if (action.pending.length === 0) {
                root.refresh();
                return;
            }

            const command = action.pending[0];
            action.pending = action.pending.slice(1);

            action.running = false;
            action.command = command;
            action.running = true;
        }

        // qmllint disable signal-handler-parameters
        onExited: (exitCode, exitStatus) => {
            action.next();
        }
        // qmllint enable signal-handler-parameters
    }
}
