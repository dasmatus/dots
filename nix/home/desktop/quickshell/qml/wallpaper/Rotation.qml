// Hourly wallpaper rotation, replacing nix/home/random_wp.nix's systemd
// service and timer.
//
// That service was WantedBy=graphical-session.target as well as
// timer-triggered, so a login painted a fresh random pick before the first
// hour ever elapsed, and a cold install (no wallpaper ever set) still got
// one. triggeredOnStart mirrors both: it fires once as soon as the shell
// starts, then every interval after.
//
// Random over the same Wallpapers/ tree the picker's own grid lists, not a
// Wallhaven fetch. The picker only knows how to apply a local file, and
// giving Rotation its own remote source would leave two different
// definitions of "the wallpaper set". A held reference to that Picker
// instance drives it, not `qs ipc call`: both live in the same process, so
// there is no socket to round-trip through and no boot race to wait out.
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root

    required property Picker picker

    Timer {
        interval: 3600000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: lister.running = true
    }

    // Same finder as Picker.qml's own `lister`, kept a second copy rather
    // than shared: this one only ever needs the freshest listing at the
    // moment it fires, never the grid's currently-displayed model.
    Process {
        id: lister

        command: ["fd", "--type", "f", "-e", "jpg", "-e", "jpeg", "-e", "png", "-e", "webp", "-e", "gif", ".", root.picker.wallpapersDir]

        stdout: StdioCollector {
            onStreamFinished: {
                const files = this.text.split("\n").filter(p => p.length > 0);
                if (files.length === 0)
                    return;

                const pick = files[Math.floor(Math.random() * files.length)];
                // record: false. A random rotation stamping over
                // outputs.json on every trigger would mean Picker's `r`
                // replays the rotation's latest guess instead of the
                // user's own last deliberate pick, which is what
                // "restore" is supposed to mean.
                root.picker.apply(pick, "*", "fill", undefined, false);
            }
        }
    }
}
