// Workspace icons for one monitor, wrapped in a Pill.
//
// Each workspace used to be one abstract Nerd Font glyph, coloured by state.
// It now renders the icons of the applications actually running in it,
// resolved the same way FocusedWindow.qml already resolves its own single
// icon: a toplevel's `wayland.appId` through DesktopEntries.byId(), with
// heuristicLookup() as a fallback for the appIds that never line up with a
// desktop file's own id. An empty workspace keeps the old dot glyph, so it
// still occupies a slot and stays clickable.
//
// Pill is adopted here for its padding and its fixed 22px height, the same
// reason every other bar module is one, NOT for its capsule fill: that stays
// transparent. This is a deliberate exception to the rest of the bar's
// pills, which sit on Theme.bgDark — a row of real app icons already
// carries its own colour, and a second background behind it would be paint
// competing with the icons rather than structure holding them apart. Leave
// the fill transparent when touching this file.
//
// Urgent, focused and active are no longer separate glyphs — the icons
// themselves say "occupied" now — but they still have to be distinguishable,
// so each stays a colour: a thin underline beneath a workspace's icons for
// the occupied cases, the dot's own colour for an empty one.
//
// The delegates read glyph names, the icon cap and iconFor off this file's
// root id. Without bound component behaviour those lookups resolve
// dynamically at each evaluation rather than binding once, which is both
// slower and a documented way to have a delegate quietly capture the wrong
// scope.
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland
import "workspaces.js" as WorkspacesMath
import ".."
import "../common"

Pill {
    id: root

    // HyprlandMonitor. Workspaces are filtered to it because the bar is
    // per-monitor: waybar had no equivalent and showed every workspace on
    // every bar.
    required property var monitor

    // Written as an escape for the same reason the header used to explain at
    // length: a private-use codepoint pasted as a literal is one careless
    // editor away from becoming a replacement character nobody notices.
    readonly property string iconEmpty: "\u{F4AA}"

    // Fallback glyph for a running toplevel whose icon could not be
    // resolved, so a lookup miss still reads as "something is here" rather
    // than a silent gap in the icon row.
    readonly property string iconUnknown: "\u{F192}"

    color: "transparent"

    // Hyprland hands these back in whatever order its IPC felt like. Sorting by
    // id keeps 1..9 from reshuffling when a workspace is created or destroyed.
    readonly property var monitorWorkspaces: {
        if (!root.monitor)
            return [];

        return Hyprland.workspaces.values.filter(ws => ws.monitor === root.monitor).sort((a, b) => a.id - b.id);
    }

    // Maps a running toplevel to an icon path. `wayland.appId` is the same
    // field FocusedWindow.qml already keys on — it is Hyprland's window
    // class surfaced through the generic wlr-foreign-toplevel-management
    // handle, reactive on its own `appIdChanged` signal, unlike the class
    // field buried in `lastIpcObject`'s static snapshot. byId() covers the
    // common case where a desktop file's own id matches the appId exactly;
    // heuristicLookup() catches the rest, first against the appId itself and
    // then, for the toplevels wlr-foreign-toplevel-management never gave an
    // appId at all, against the window title.
    function iconFor(toplevel: var): string {
        const appId = toplevel?.wayland?.appId ?? "";
        const title = toplevel?.title ?? "";

        // Both heuristicLookup calls are guarded the same way: a toplevel
        // with neither an appId nor a title (some layer-shell-adjacent
        // clients report neither) must not reach it with "", which is not a
        // real heuristic case and not worth asking DesktopEntries about.
        const entry = (appId !== "" ? DesktopEntries.byId(appId) : null) ?? (appId !== "" ? DesktopEntries.heuristicLookup(appId) : null) ?? (title !== "" ? DesktopEntries.heuristicLookup(title) : null);

        return entry?.icon ? Quickshell.iconPath(entry.icon, true) : "";
    }

    Repeater {
        model: root.monitorWorkspaces

        delegate: Item {
            id: workspace

            required property var modelData

            readonly property var toplevels: workspace.modelData.toplevels.values
            readonly property bool occupied: workspace.toplevels.length > 0
            readonly property int shown: WorkspacesMath.shownCount(workspace.toplevels.length, Theme.barWorkspaceIconCap)
            readonly property int overflow: WorkspacesMath.overflowCount(workspace.toplevels.length, Theme.barWorkspaceIconCap)

            // Whether this workspace gets the underline: any state a user
            // would want to notice at a glance that a plain occupied,
            // unfocused, inactive workspace does not.
            readonly property bool marked: workspace.modelData.urgent || workspace.modelData.focused || workspace.modelData.active

            readonly property color stateColor: {
                if (workspace.modelData.urgent)
                    return Theme.red;

                if (workspace.modelData.focused)
                    return Theme.accent;

                return workspace.occupied || workspace.modelData.active ? Theme.muted : Theme.selection;
            }

            implicitWidth: column.implicitWidth
            implicitHeight: column.implicitHeight

            Column {
                id: column

                anchors.centerIn: parent
                spacing: 2

                Row {
                    id: iconRow

                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 4

                    Text {
                        visible: !workspace.occupied
                        text: root.iconEmpty
                        color: workspace.stateColor

                        font.family: Theme.fontUi
                        font.pixelSize: Theme.barFontSize
                        font.bold: true
                    }

                    Repeater {
                        model: workspace.toplevels.slice(0, workspace.shown)

                        delegate: Item {
                            id: iconSlot

                            required property var modelData

                            readonly property string iconSource: root.iconFor(iconSlot.modelData)

                            implicitWidth: Theme.barIconSize
                            implicitHeight: Theme.barIconSize

                            Image {
                                anchors.fill: parent
                                visible: iconSlot.iconSource !== ""

                                source: iconSlot.iconSource

                                sourceSize.width: Theme.barIconSize
                                sourceSize.height: Theme.barIconSize
                                fillMode: Image.PreserveAspectFit
                            }

                            Text {
                                anchors.centerIn: parent
                                visible: iconSlot.iconSource === ""
                                text: root.iconUnknown
                                color: Theme.muted

                                font.family: Theme.fontUi
                                font.pixelSize: Theme.barFontSize
                                font.bold: true
                            }
                        }
                    }

                    Text {
                        visible: workspace.overflow > 0
                        text: `+${workspace.overflow}`
                        color: Theme.muted

                        font.family: Theme.fontUi
                        font.pixelSize: Theme.barFontSize
                        font.bold: true
                    }
                }

                Rectangle {
                    width: iconRow.implicitWidth
                    height: 2
                    radius: 1

                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: workspace.marked
                    color: workspace.stateColor
                }
            }

            MouseArea {
                anchors.fill: parent

                cursorShape: Qt.PointingHandCursor
                onClicked: Hyprland.dispatch(`workspace ${workspace.modelData.id}`)
            }
        }
    }
}
