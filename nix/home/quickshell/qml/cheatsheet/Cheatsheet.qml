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
import "../common"

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

    // The flat index each group's first row starts at, so a row nested two
    // Repeaters deep can compare itself against `selected` without the
    // groups themselves being flattened out of the JSON they were loaded
    // from — Up/Down moves through one continuous list even though the
    // layout stays grouped.
    readonly property var groupOffsets: {
        let offset = 0;
        return root.groups.map(g => {
            const start = offset;
            offset += g.items.length;
            return start;
        });
    }

    readonly property int totalItems: root.groups.reduce((sum, g) => sum + g.items.length, 0)

    property int selected: 0

    // Wraps, matching Launcher's own move().
    function moveSelection(delta: int): void {
        const count = root.totalItems;
        if (count === 0)
            return;

        root.selected = (root.selected + delta % count + count) % count;
    }

    IpcHandler {
        target: "cheatsheet"

        function toggle(): void {
            window.visible = !window.visible;
            if (window.visible)
                root.selected = 0;
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

        Chrome {
            id: panel

            anchors.centerIn: parent

            width: Math.min(920, parent.width - 80)
            height: Math.min(scroll.contentHeight + 72, parent.height - 80)

            padding: 24

            focus: true

            title: "Keybinds"
            hints: [
                {
                    key: "↑↓/jk",
                    label: "browse"
                },
                {
                    key: "Esc/Enter",
                    label: "close"
                }
            ]

            Keys.onEscapePressed: window.visible = false
            // Nothing on a read-only reference to commit, so Enter closes it
            // too rather than doing nothing.
            Keys.onReturnPressed: window.visible = false
            Keys.onEnterPressed: window.visible = false
            Keys.onUpPressed: root.moveSelection(-1)
            Keys.onDownPressed: root.moveSelection(1)

            // No focused text field on this surface to steal j/k as literal
            // characters, so they alias the arrows Vim-style.
            Keys.onPressed: event => {
                if (event.key === Qt.Key_J) {
                    root.moveSelection(1);
                    event.accepted = true;
                } else if (event.key === Qt.Key_K) {
                    root.moveSelection(-1);
                    event.accepted = true;
                }
            }

            Flickable {
                id: scroll

                anchors.fill: parent

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
                            required property int index

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

                                    // Where this row sits in root.selected's
                                    // flat numbering — groupOffsets carries
                                    // the running total so this doesn't need
                                    // the groups flattened to compare.
                                    readonly property int flatIndex: root.groupOffsets[section.index] + row.index

                                    Layout.fillWidth: true

                                    spacing: 16

                                    Rectangle {
                                        // Zebra striping came from eww's
                                        // :nth-child(2n); here it is the row
                                        // index, which survives reordering.
                                        // The selected row overrides both.
                                        Layout.preferredWidth: 240
                                        Layout.preferredHeight: keyLabel.implicitHeight + 6

                                        radius: 6
                                        color: row.flatIndex === root.selected ? Theme.selection : (row.index % 2 === 0 ? Theme.bgDark : "transparent")

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
