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

    // JsonAdapter has no `root` property on this Quickshell build. Reading a
    // bare `root` off it is silently always undefined, which is why SUPER+/
    // used to render an empty sheet. Only a property DECLARED on the adapter
    // instance gets populated from the file; `groups` below is that property.
    // qmllint disable unresolved-type
    readonly property var groups: keybindsFile.adapter.groups

    property var keybindsFile: FileView {
        path: `${Quickshell.shellDir}/cheatsheet/keybinds.json`
        adapter: JsonAdapter {
            property var groups: []
        }
    }
    // qmllint enable unresolved-type

    // How far one Up/Down (or j/k) press moves the list. Close to one
    // row's height, so a single press is visible without feeling like a
    // page flip. There is nothing here to select: this is a read-only
    // reference with no per-row action, so the keys just move the
    // viewport, the same thing they'd do to a terminal pager.
    readonly property real scrollStep: 40

    function scrollBy(delta: real): void {
        const maxY = Math.max(0, scroll.contentHeight - scroll.height);
        scroll.contentY = Math.min(maxY, Math.max(0, scroll.contentY + delta));
    }

    IpcHandler {
        target: "cheatsheet"

        function toggle(): void {
            window.visible = !window.visible;
            if (window.visible)
                scroll.contentY = 0;
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
            // panel.implicitHeight is pure chrome overhead here. The
            // Flickable body reports no implicitHeight of its own, so this
            // is the real header+footer cost plus the list's own height,
            // still capped against the screen the way it always was.
            height: Math.min(scroll.contentHeight + panel.implicitHeight, parent.height - 80)

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
            Keys.onUpPressed: root.scrollBy(-root.scrollStep)
            Keys.onDownPressed: root.scrollBy(root.scrollStep)

            // No focused text field on this surface to steal j/k as literal
            // characters, so they alias the arrows Vim-style.
            Keys.onPressed: event => {
                if (event.key === Qt.Key_J) {
                    root.scrollBy(root.scrollStep);
                    event.accepted = true;
                } else if (event.key === Qt.Key_K) {
                    root.scrollBy(-root.scrollStep);
                    event.accepted = true;
                }
            }

            Flickable {
                id: scroll

                Layout.fillWidth: true
                Layout.fillHeight: true

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
