// The Displays settings page: every connected monitor with its resolution,
// position, scale and transform, plus the way into the spatial arranger.
// Loaded by Settings.qml through a `Loader { source: "pages/displays.qml" }`,
// the same lowercase-filename-by-source-URL idiom pages/security.qml and
// pages/wallpaper.qml use, and for the identical reason — a lowercase
// filename cannot be a QML type name.
//
// Why this page reads rather than edits, when the wallpaper page next to it
// fully replaces its old overlay:
//
// monitors/Arrange.qml is a spatial drag editor built around a fixed
// 720x420 canvas beside a 220px form, with 20px between them — 960px of
// width before any chrome. The Settings content column is
// Theme.settingsPanelWidthFactor (0.72) of the screen minus the 260px
// sidebar and row padding: roughly 1090px on a 1920-wide display, but only
// about 690px on a 1366-wide one. So the arranger fits here and does not fit
// generally, and shrinking a drag canvas is not a layout tweak — dragging a
// monitor rectangle into place is the whole interaction, and it degrades
// badly before it degrades visibly.
//
// Rather than embed something that silently becomes unusable on a smaller
// screen, this page consolidates what it can: the answer to "what monitors
// do I have and how are they set up" now lives in Settings with everything
// else, and SUPER+M still goes straight to the arranger for the editing the
// arranger is good at. Decomposing Arrange.qml so its canvas can size to its
// container is a real piece of work and deserves its own task rather than
// riding along in this one.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../.."
import "../../common"
import ".."

ColumnLayout {
    id: root

    spacing: Theme.settingsGroupGap

    ColumnLayout {
        Layout.fillWidth: true

        spacing: Theme.settingsRowGap

        Repeater {
            model: Quickshell.screens

            delegate: Rectangle {
                id: monitorCard

                required property var modelData

                Layout.fillWidth: true
                Layout.preferredHeight: body.implicitHeight + Theme.settingsRowPadding * 2

                radius: Theme.settingsRadius
                color: Theme.bgDark

                ColumnLayout {
                    id: body

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Theme.settingsRowPadding
                    anchors.rightMargin: Theme.settingsRowPadding

                    spacing: 4

                    Text {
                        text: monitorCard.modelData.name
                        color: Theme.fg

                        font.family: Theme.fontUi
                        font.pointSize: Theme.settingsRowTitleFontSize
                        font.bold: true
                    }

                    // Geometry as the compositor actually reports it, not as
                    // any config file wishes it were: a monitor whose
                    // override failed to apply reads differently here, which
                    // is the point of showing it.
                    Text {
                        text: `${monitorCard.modelData.width}×${monitorCard.modelData.height} at ${monitorCard.modelData.x},${monitorCard.modelData.y}`
                        color: Theme.muted

                        font.family: Theme.fontUi
                        font.pointSize: Theme.settingsRowDescFontSize
                    }

                    Text {
                        text: `scale ${monitorCard.modelData.devicePixelRatio.toFixed(2)}`
                        color: Theme.muted

                        font.family: Theme.fontUi
                        font.pointSize: Theme.settingsRowDescFontSize
                    }
                }
            }
        }
    }

    // The way to the arranger. SUPER+M reaches it directly too — this row
    // exists so the page is not a dead end for someone who arrived through
    // the sidebar and has no reason to know the bind.
    SettingsRow {
        Layout.fillWidth: true

        title: "Arrange monitors"
        description: "Drag monitors into position, set scale and rotation. Opens its own full-screen editor."
        clickable: true

        // Through the same `qs ipc call` any keybind uses, rather than
        // reaching for Arrange directly: this page is loaded by URL and has
        // no handle on the shell's other surfaces, and going through the IPC
        // means the sidebar route and the SUPER+M route are the identical
        // code path rather than two that can diverge.
        onClicked: arrangeIpc.running = true

        Text {
            text: "\u{F0142}"
            color: Theme.muted

            font.family: Theme.fontUi
            font.pointSize: Theme.settingsRowTitleFontSize
        }
    }

    Process {
        id: arrangeIpc

        command: ["qs", "ipc", "call", "arrange", "open"]
    }

    Item {
        Layout.fillHeight: true
    }
}
