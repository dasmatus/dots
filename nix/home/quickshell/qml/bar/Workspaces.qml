// Workspace dots for one monitor.
//
// Not a Pill: waybar gave `#workspaces button` the capsule base and then took
// it straight back with `background-color: transparent`, so what you actually
// saw was bare glyphs carrying their state in colour alone. This reproduces
// that rather than the stylesheet that fought itself.
//
// The glyphs are the same Nerd Font codepoints waybar used, written as escapes
// because a private-use codepoint pasted as a literal is one careless editor
// away from becoming a replacement character nobody notices.
// The delegate reads the glyph names off this file's root id. Without bound
// component behaviour those lookups resolve dynamically at each evaluation
// rather than binding once, which is both slower and a documented way to have
// a delegate quietly capture the wrong scope.
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Hyprland
import ".."

Row {
    id: root

    // HyprlandMonitor. Workspaces are filtered to it because the bar is
    // per-monitor: waybar had no equivalent and showed every workspace on
    // every bar.
    required property var monitor

    readonly property string iconOccupied: "\u{F192}"
    readonly property string iconUrgent: "\u{F0D59}"
    readonly property string iconEmpty: "\u{F4AA}"
    readonly property string iconVisible: "\u{25CF}"

    // Hyprland hands these back in whatever order its IPC felt like. Sorting by
    // id keeps 1..9 from reshuffling when a workspace is created or destroyed.
    readonly property var monitorWorkspaces: {
        if (!root.monitor)
            return [];

        return Hyprland.workspaces.values.filter(ws => ws.monitor === root.monitor).sort((a, b) => a.id - b.id);
    }

    spacing: 2

    Repeater {
        model: root.monitorWorkspaces

        delegate: Text {
            id: dot

            required property var modelData

            readonly property bool occupied: dot.modelData.toplevels.values.length > 0

            text: {
                if (dot.modelData.urgent)
                    return root.iconUrgent;

                if (dot.modelData.focused)
                    return root.iconOccupied;

                if (dot.modelData.active)
                    return root.iconVisible;

                return dot.occupied ? root.iconOccupied : root.iconEmpty;
            }

            color: {
                if (dot.modelData.urgent)
                    return Theme.red;

                if (dot.modelData.focused)
                    return Theme.accent;

                return dot.occupied ? Theme.muted : Theme.selection;
            }

            font.family: Theme.fontUi
            font.pixelSize: Theme.barFontSize
            font.bold: true

            leftPadding: 6
            rightPadding: 6

            MouseArea {
                anchors.fill: parent

                cursorShape: Qt.PointingHandCursor
                onClicked: Hyprland.dispatch(`workspace ${dot.modelData.id}`)
            }
        }
    }
}
