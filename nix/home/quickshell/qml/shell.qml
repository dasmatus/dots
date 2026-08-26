// Entry point for the dots Quickshell shell.
//
// Phase 0 only proves the plumbing: that the tree loads, that Theme resolves
// against rust/palette.json, and that a layer-shell panel reaches every
// monitor. The bar, notification daemon, OSD, launcher and settings form
// replace this placeholder in the phases that follow.
//
// Variants over Quickshell.screens rather than one window: it builds and tears
// down a panel per monitor as they come and go, which waybar needed a service
// restart to manage.
import Quickshell
import QtQuick

ShellRoot {
    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: panel

            required property var modelData

            screen: panel.modelData
            color: Theme.bg

            anchors {
                top: true
                left: true
                right: true
            }

            implicitHeight: 32

            Text {
                anchors.centerIn: parent

                text: `quickshell up on ${panel.modelData.name}`
                color: Theme.accent
                font.family: Theme.fontUi
                font.pointSize: Theme.fontSize
            }
        }
    }
}
