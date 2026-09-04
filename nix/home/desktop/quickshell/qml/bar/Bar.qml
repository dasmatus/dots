// One bar, for one monitor.
//
// The window is transparent and the modules are capsules floating on the
// desktop, which is what waybar's `window#waybar { background-color:
// transparent }` bought. Blur comes from the compositor, not from here.
//
// Left, centre and right are anchored rather than packed into a single row.
// The centre module has to sit at the middle of the screen and stay there,
// which a three-cell row cannot promise once the left and right groups differ
// in width, and they always do.
import QtQuick
import Quickshell
import Quickshell.Hyprland
import ".."

PanelWindow {
    id: root

    required property var modelData

    // Hyprland's own monitor object for this screen. The workspace and window
    // modules are per-monitor and need it; Quickshell's ScreenInfo does not
    // carry Hyprland state.
    readonly property var monitor: Hyprland.monitorFor(root.modelData)

    screen: root.modelData
    color: "transparent"

    anchors {
        top: true
        left: true
        right: true
    }

    implicitHeight: Theme.barHeight

    Item {
        anchors.fill: parent
        anchors.leftMargin: Theme.barSpacing * 2
        anchors.rightMargin: Theme.barSpacing * 2

        Workspaces {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter

            monitor: root.monitor
        }

        FocusedWindow {
            anchors.centerIn: parent

            monitor: root.monitor
        }

        Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            spacing: Theme.barSpacing

            Network {}

            Battery {}

            Drives {}

            Keymap {}

            Clock {}

            Tray {}
        }
    }
}
