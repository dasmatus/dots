// The keybind cheatsheet, reached with SUPER+/.
//
// Replaces the last eww window. eww kept this list as one flat array carrying
// a `first` boolean per row, because eww 0.6.0's `for` could not iterate a
// field of a loop variable, so a nested shape took down the whole config. A
// Repeater inside a Repeater is unremarkable here, so the data is grouped and
// the marker row is gone.
//
// eww also needed a sentinel file under $XDG_STATE_HOME and a shell script
// that slept two seconds waiting for its own IPC socket, so that the window
// opened once per install. That was machinery for a first-run popup, and it is
// not reproduced: the shell knows whether it has shown this, and a first-run
// greeting that appears once is worth less than a cheatsheet that opens
// instantly whenever it is asked for.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import ".."

Scope {
    id: root

    readonly property var focusedScreen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) ?? null

    // qmllint disable unresolved-type
    readonly property var groups: keybindsFile.adapter.root?.groups ?? []

    property var keybindsFile: FileView {
        path: `${Quickshell.shellDir}/cheatsheet/keybinds.json`
        adapter: JsonAdapter {}
    }
    // qmllint enable unresolved-type

    IpcHandler {
        target: "cheatsheet"

        function toggle(): void {
            window.visible = !window.visible;
        }

        function close(): void {
            window.visible = false;
        }
    }

    PanelWindow {
        id: window

        screen: root.focusedScreen
        color: "transparent"
        visible: false

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        WlrLayershell.namespace: "dots-cheatsheet"

        anchors {
            top: true
            left: true
            right: true
            bottom: true
        }

        exclusiveZone: 0

        onVisibleChanged: {
            if (window.visible)
                panel.forceActiveFocus();
        }

        MouseArea {
            anchors.fill: parent

            onClicked: window.visible = false
        }

        Rectangle {
            id: panel

            anchors.centerIn: parent

            width: Math.min(920, parent.width - 80)
            height: Math.min(scroll.contentHeight + 72, parent.height - 80)

            radius: Theme.launcherRadius
            color: Qt.alpha(Theme.bg, 0.95)
            border.width: 2
            border.color: Theme.accent

            focus: true

            Keys.onEscapePressed: window.visible = false

            MouseArea {
                anchors.fill: parent
            }

            Text {
                id: heading

                anchors.top: parent.top
                anchors.left: parent.left
                anchors.topMargin: 18
                anchors.leftMargin: 24

                text: "Keybinds"
                color: Theme.accent

                font.family: Theme.fontUi
                font.pointSize: 14
                font.bold: true
            }

            Flickable {
                id: scroll

                anchors.top: heading.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: 24
                anchors.topMargin: 12

                contentWidth: width
                contentHeight: column.implicitHeight
                clip: true

                ColumnLayout {
                    id: column

                    width: scroll.width
                    spacing: 16

                    Repeater {
                        model: root.groups

                        delegate: ColumnLayout {
                            id: section

                            required property var modelData

                            Layout.fillWidth: true

                            spacing: 4

                            Text {
                                text: section.modelData.name
                                color: Theme.cyan

                                font.family: Theme.fontUi
                                font.pointSize: 11
                                font.bold: true
                                font.capitalization: Font.AllUppercase
                            }

                            Repeater {
                                model: section.modelData.items

                                delegate: RowLayout {
                                    id: row

                                    required property var modelData
                                    required property int index

                                    Layout.fillWidth: true

                                    spacing: 16

                                    Rectangle {
                                        // Zebra striping came from eww's
                                        // :nth-child(2n); here it is the row
                                        // index, which survives reordering.
                                        Layout.preferredWidth: 240
                                        Layout.preferredHeight: keyLabel.implicitHeight + 6

                                        radius: 6
                                        color: row.index % 2 === 0 ? Theme.bgDark : "transparent"

                                        Text {
                                            id: keyLabel

                                            anchors.left: parent.left
                                            anchors.verticalCenter: parent.verticalCenter
                                            anchors.leftMargin: 8

                                            text: row.modelData.key
                                            color: Theme.fg

                                            font.family: Theme.fontMono
                                            font.pointSize: 10
                                            font.bold: true
                                        }
                                    }

                                    Text {
                                        Layout.fillWidth: true

                                        text: row.modelData.desc
                                        color: Theme.fgDark

                                        font.family: Theme.fontUi
                                        font.pointSize: 10

                                        elide: Text.ElideRight
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
