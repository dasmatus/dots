// The settings form, reached with SUPER+comma.
//
// Edits the installer-written settings.nix through rust/settings-global, which
// survives the migration because it never owned a surface: beamenu-canvas drew
// its form over JSON-RPC while the crate did the parsing, the validation and
// the pkexec re-exec when the file is root-owned.
//
// This talks to `dump` and `set` rather than `serve`. The JSON-RPC mode exists
// to feed beamenu-canvas a component tree, and with the canvas gone the plain
// CLI is the smaller interface: one process to read every field, one per field
// changed to write it back.
//
// Writes are per-field on purpose. `set` validates one key at a time and
// re-execs itself under pkexec when it has to, so a failed field fails alone
// instead of taking a whole document with it.
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

    property var fields: []

    // Keyed by field key. Only what the user actually touched is written back,
    // so opening the form and closing it changes nothing on disk.
    property var edits: ({})

    property string status: ""

    // Which row Up/Down highlights. A cursor only — editing still needs a
    // click, same as before, so arrowing past a field never steals focus
    // out from under whatever the mouse last put it on.
    property int selected: 0

    function load(): void {
        root.edits = {};
        root.status = "";
        root.selected = 0;
        loader.running = false;
        loader.running = true;
    }

    // Wraps, matching Launcher's own move().
    function moveSelection(delta: int): void {
        const count = root.fields.length;
        if (count === 0)
            return;

        root.selected = (root.selected + delta % count + count) % count;
    }

    function valueOf(field: var): var {
        return field.key in root.edits ? root.edits[field.key] : field.value;
    }

    function edit(key: string, value: var): void {
        // Reassigned rather than mutated: QML does not see a property change
        // when an object's contents are modified in place, so the bindings
        // reading it would keep showing the old value.
        const next = Object.assign({}, root.edits);
        next[key] = value;
        root.edits = next;
    }

    function save(): void {
        const keys = Object.keys(root.edits);
        if (keys.length === 0) {
            root.status = "Nothing changed";
            return;
        }

        root.status = `Writing ${keys.length} field${keys.length === 1 ? "" : "s"}…`;
        writer.pending = keys.slice();
        writer.next();
    }

    IpcHandler {
        target: "settings"

        function open(): void {
            root.load();
            window.visible = true;
        }

        function close(): void {
            window.visible = false;
        }

        function toggle(): void {
            if (window.visible) {
                window.visible = false;
            } else {
                root.load();
                window.visible = true;
            }
        }
    }

    Process {
        id: loader

        command: ["global-settings", "dump"]

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.fields = JSON.parse(this.text);
                } catch (error) {
                    root.fields = [];
                    root.status = "Could not read settings";
                }
            }
        }
    }

    Process {
        id: writer

        property var pending: []

        function next(): void {
            if (writer.pending.length === 0) {
                root.status = "Saved";
                root.load();
                return;
            }

            const key = writer.pending[0];
            writer.pending = writer.pending.slice(1);

            const value = root.edits[key];
            writer.running = false;
            writer.command = ["global-settings", "set", key, typeof value === "boolean" ? (value ? "true" : "false") : `${value}`];
            writer.running = true;
        }

        // Process.exited carries a QProcess::ExitStatus second argument whose
        // type Quickshell does not export, so the linter cannot compile the
        // handler's signature even though it runs.
        // qmllint disable signal-handler-parameters
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0) {
                root.status = "A field was rejected, see journalctl";
                return;
            }

            writer.next();
        }
        // qmllint enable signal-handler-parameters
    }

    PanelWindow {
        id: window

        screen: root.focusedScreen
        color: "transparent"
        visible: false

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        WlrLayershell.namespace: "dots-settings"

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

            width: Math.min(680, parent.width - 80)
            height: Math.min(form.implicitHeight + 96, parent.height - 80)

            padding: 24

            focus: true

            title: "Settings"
            hints: [
                {
                    key: "↑↓",
                    label: "move"
                },
                {
                    key: "Enter",
                    label: "save"
                },
                {
                    key: "Esc",
                    label: "close"
                }
            ]

            Keys.onEscapePressed: window.visible = false
            Keys.onReturnPressed: root.save()
            Keys.onEnterPressed: root.save()

            // Arrows only, unlike Arrange/Picker/Cheatsheet's j/k alias: this
            // surface has real text fields, and a "j" typed into one while it
            // has focus must land in the field, not get stolen as a move.
            Keys.onUpPressed: root.moveSelection(-1)
            Keys.onDownPressed: root.moveSelection(1)

            ColumnLayout {
                id: form

                anchors.fill: parent

                spacing: 14

                Repeater {
                    model: root.fields

                    delegate: RowLayout {
                        id: row

                        required property var modelData
                        required property int index

                        Layout.fillWidth: true

                        spacing: 16

                        Text {
                            Layout.preferredWidth: 200

                            text: row.modelData.label
                            color: row.index === root.selected ? Theme.accent : Theme.fgDark

                            font.family: Theme.fontUi
                            font.pointSize: 10
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 32

                            visible: row.modelData.type === "text"

                            radius: 6
                            color: Theme.bgDark
                            border.width: 1
                            border.color: Theme.border

                            TextInput {
                                anchors.fill: parent
                                anchors.leftMargin: 10
                                anchors.rightMargin: 10

                                text: `${root.valueOf(row.modelData)}`
                                color: Theme.fg

                                font.family: Theme.fontUi
                                font.pointSize: 10

                                verticalAlignment: TextInput.AlignVCenter
                                clip: true
                                selectByMouse: true
                                selectionColor: Theme.accent
                                selectedTextColor: Theme.bg

                                onTextEdited: root.edit(row.modelData.key, text)

                                // TextInput answers Return itself rather than
                                // letting it bubble to the panel's own
                                // handler, so the grammar's commit/cancel
                                // keys are repeated here — the same reason
                                // Field.qml and Launcher's search box wire
                                // them on the input directly rather than on
                                // an ancestor.
                                Keys.onReturnPressed: root.save()
                                Keys.onEnterPressed: root.save()
                                Keys.onEscapePressed: window.visible = false
                            }
                        }

                        Rectangle {
                            Layout.preferredWidth: 44
                            Layout.preferredHeight: 24

                            visible: row.modelData.type === "checkbox"

                            radius: 12
                            color: root.valueOf(row.modelData) ? Theme.accent : Theme.selection

                            Rectangle {
                                width: 18
                                height: 18
                                radius: 9

                                anchors.verticalCenter: parent.verticalCenter
                                x: root.valueOf(row.modelData) ? parent.width - width - 3 : 3

                                color: Theme.bg

                                Behavior on x {
                                    NumberAnimation {
                                        duration: 90
                                    }
                                }
                            }

                            MouseArea {
                                anchors.fill: parent

                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.edit(row.modelData.key, !root.valueOf(row.modelData))
                            }
                        }

                        Item {
                            Layout.fillWidth: row.modelData.type === "checkbox"
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: 8

                    spacing: 12

                    Text {
                        Layout.fillWidth: true

                        text: root.status
                        color: Theme.muted

                        font.family: Theme.fontUi
                        font.pointSize: 9
                    }

                    Rectangle {
                        Layout.preferredWidth: 110
                        Layout.preferredHeight: 32

                        radius: 8
                        color: Object.keys(root.edits).length > 0 ? Theme.accent : Theme.selection

                        Text {
                            anchors.centerIn: parent

                            text: "Save"
                            color: Object.keys(root.edits).length > 0 ? Theme.bg : Theme.muted

                            font.family: Theme.fontUi
                            font.pointSize: 10
                            font.bold: true
                        }

                        MouseArea {
                            anchors.fill: parent

                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.save()
                        }
                    }
                }
            }
        }
    }
}
