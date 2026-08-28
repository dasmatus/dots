// Home plus every currently-mounted device. Navigation calls
// Devices.requestOpen, the signal Files.qml has listened for since Task
// 1's Connections block, so nothing in Files.qml needs touching for this
// file's clicks to work. Eject is a direct in-process call on the
// singleton instead: it is an immediate action, not something another
// surface needs to react to.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import "../services"
import "../services/devices.js" as DevicesMath
import ".."

ColumnLayout {
    id: root

    spacing: 4

    Text {
        text: "Home"
        color: Theme.fg
        font.family: Theme.fontUi

        MouseArea {
            anchors.fill: parent
            onClicked: Devices.requestOpen(Quickshell.env("HOME"))
        }
    }

    Repeater {
        model: Devices.devices

        delegate: RowLayout {
            id: entry

            required property var modelData

            Layout.fillWidth: true

            Text {
                Layout.fillWidth: true
                text: DevicesMath.displayLabel(entry.modelData)
                color: Theme.fg
                font.family: Theme.fontUi
                elide: Text.ElideRight

                MouseArea {
                    anchors.fill: parent
                    onClicked: Devices.requestOpen(entry.modelData.mountPoint)
                }
            }

            Text {
                text: "⏏"
                color: Theme.muted
                font.family: Theme.fontUi

                MouseArea {
                    anchors.fill: parent
                    onClicked: Devices.eject(entry.modelData.path, entry.modelData.diskPath)
                }
            }
        }
    }
}
