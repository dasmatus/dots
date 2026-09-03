// Drives pill: how many removable devices are mounted right now.
//
// Devices.qml is a singleton, and a pragma Singleton has no constructor
// line for shell.qml to call the way Bar.qml instantiates every other
// module. It stays, in its own words, "genuinely inert" until something
// reads one of its properties, but that first read belongs to the launcher,
// not to this pill. shell.qml instantiates Launcher {} unconditionally at
// startup, and Launcher's own `results` binding evaluates eagerly against
// the empty startup query, which falls through to providers.deviceRows(""),
// reading Devices.flat before this bar is ever drawn. `mounted` below,
// aliasing Devices.devices, is only this pill's own read of an already-
// running singleton. Delete this pill and the bar loses its summary count;
// the service itself keeps running regardless, kept awake by the launcher.
//
// Hidden while nothing is mounted, the same way Battery.qml hides itself on
// a machine with no battery: an empty tray has nothing to report.
//
// Interactive only with exactly one device mounted. Middle-click ejects it,
// the same button Tray.qml gives a StatusNotifierItem's secondary action,
// but a pill reading "2" has no single device a click could mean, so past
// one it stays a plain arrow cursor and does nothing.
import QtQuick
import "../services"
import "../common"
import ".."

Pill {
    id: root

    readonly property var mounted: Devices.devices

    visible: root.mounted.length > 0
    interactive: root.mounted.length === 1

    onMiddleClicked: {
        const device = root.mounted[0];
        Devices.eject(device.path, device.diskPath);
    }

    Text {
        text: `\u{F02CA} ${root.mounted.length}`
        color: Theme.fg

        font.family: Theme.fontUi
        font.pixelSize: Theme.barFontSize
        font.bold: true
    }
}
