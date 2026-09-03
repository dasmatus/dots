// The input end of the pane: a prompt field, a backend and model picker, and
// one button that is Send while the thread is idle and Stop while a turn runs.
//
// One button rather than two, because only one of them is ever the right thing
// to press, and a Stop sitting greyed beside Send for most of a session teaches
// the reader to ignore that corner of the pane.
//
// AN INTERRUPT IS NOT A FAILURE. Pressing Stop sends op:"interrupt", the turn
// ends with stop "interrupted", and no error event arrives at all. Nothing here
// treats it as an error, and nothing downstream does either.
//
// Enter sends and Shift+Enter opens a line, the arrangement every chat input on
// this machine already uses. A bare TextEdit in a Flickable rather than
// QtQuick.Controls' TextArea: the shell tree is QtQuick only, installer.qml is
// the one entry point that pulls Controls in, and a Controls widget here would
// paint itself in the default style instead of the palette. The model picker is
// a Pill that cycles for the same reason a ComboBox is not.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import ".."
import "../common"

Rectangle {
    id: root

    property var backends: []
    property string backend: ""
    property string model: ""
    property bool busy: false

    readonly property alias text: input.text

    signal submitted(string text)
    signal interrupted
    signal backendPicked(string id)
    signal modelPicked(string name)

    // The picked backend's own entry, or null before one is picked.
    readonly property var picked: {
        for (const entry of root.backends) {
            if (entry.id === root.backend)
                return entry;
        }
        return null;
    }

    // The models the picked backend offers, or an empty list for one the
    // daemon has not reached. Empty is not an error: ollama with nothing
    // pulled and a backend the daemon cannot reach both land here, and both
    // mean "nothing to choose from" rather than "something broke".
    readonly property var models: root.picked ? (root.picked.models ?? []) : []

    implicitHeight: column.implicitHeight + Theme.askGutter * 2

    radius: Theme.askRadius
    color: Theme.bgDark
    border.width: 1
    border.color: input.activeFocus ? Theme.accent : Theme.border

    function focusInput(): void {
        input.forceActiveFocus();
    }

    function submit(): void {
        const body = input.text.trim();
        if (body === "")
            return;

        input.text = "";
        root.submitted(body);
    }

    // Steps to the next model the backend offers and wraps. A list of two or
    // three names does not need a dropdown, and a dropdown is the one widget
    // here that would have to come from QtQuick.Controls.
    function cycleModel(): void {
        if (root.models.length === 0)
            return;

        const at = root.models.indexOf(root.model);
        root.modelPicked(root.models[(at + 1) % root.models.length]);
    }

    ColumnLayout {
        id: column

        anchors.fill: parent
        anchors.margins: Theme.askGutter

        spacing: 8

        Flickable {
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(Math.max(input.implicitHeight, 22), Theme.askComposerHeight)

            contentWidth: width
            contentHeight: input.implicitHeight
            clip: true

            // Keeps the caret in view while typing past the visible height,
            // which a bare Flickable around a TextEdit does not do on its own.
            onContentHeightChanged: {
                if (contentHeight > height)
                    contentY = contentHeight - height;
            }

            TextEdit {
                id: input

                width: parent.width

                color: Theme.fg

                font.family: Theme.fontUi
                font.pointSize: 10

                wrapMode: TextEdit.Wrap
                selectByMouse: true
                selectionColor: Theme.accent
                selectedTextColor: Theme.bg

                // Shift+Enter has to be seen before Enter is swallowed, which
                // is why this is one handler and not Keys.onReturnPressed:
                // that handler gets no modifier, and a prompt that cannot hold
                // a second line is not a prompt.
                Keys.onPressed: event => {
                    if (event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter)
                        return;

                    if (event.modifiers & Qt.ShiftModifier)
                        return;

                    event.accepted = true;
                    root.submit();
                }

                Text {
                    anchors.left: parent.left
                    anchors.top: parent.top

                    text: root.busy ? "Running. Escape stops it." : "Ask"
                    color: Theme.muted
                    visible: input.text === ""

                    font.family: Theme.fontUi
                    font.pointSize: 10
                }
            }
        }

        // The backend's own detail line, and the pane's one honest warning.
        //
        // `detail` is null while a backend is ready and carries a reason when
        // it is not. It is also where the harness says the widening the spec's
        // security section names out loud: the CLI still applies the user's own
        // ~/.claude/settings.json allow rules, so a tool matching those is
        // approved inside the CLI and never reaches the approval prompt here.
        // Anyone expecting this pane to be a second gate in front of a broad
        // Bash(git *) rule is wrong, and this line is where they find out.
        Text {
            Layout.fillWidth: true

            visible: root.picked !== null && (root.picked.detail ?? "") !== ""
            text: root.picked ? (root.picked.detail ?? "") : ""
            color: Theme.muted

            font.family: Theme.fontUi
            font.pointSize: 8

            wrapMode: Text.Wrap
        }

        RowLayout {
            Layout.fillWidth: true

            spacing: 6

            Repeater {
                model: root.backends

                delegate: Pill {
                    id: backendPill

                    required property var modelData

                    readonly property bool active: backendPill.modelData.id === root.backend
                    readonly property bool reachable: backendPill.modelData.state === "ready"

                    interactive: true
                    color: backendPill.active ? Theme.accent : Theme.bgDarker

                    onClicked: root.backendPicked(backendPill.modelData.id)

                    Text {
                        text: backendPill.modelData.label
                        // A backend whose toggle is on but which has no
                        // credential, or which refused a connection, still
                        // lists. Greyed rather than hidden, because "it is not
                        // here" and "it is here and cannot answer" are
                        // different problems and only one of them is fixed by
                        // opening the settings.
                        color: backendPill.active ? Theme.bg : (backendPill.reachable ? Theme.fg : Theme.muted)

                        font.family: Theme.fontUi
                        font.pointSize: 9
                        font.bold: true
                    }
                }
            }

            Item {
                Layout.fillWidth: true
            }

            Pill {
                visible: root.models.length > 0

                interactive: true
                color: Theme.bgDarker

                onClicked: root.cycleModel()

                Text {
                    text: root.model === "" ? "default model" : root.model
                    color: Theme.fgDark

                    font.family: Theme.fontMono
                    font.pointSize: 9
                }
            }

            Pill {
                interactive: true
                color: root.busy ? Theme.red : Theme.accent

                onClicked: {
                    if (root.busy) {
                        root.interrupted();
                        return;
                    }
                    root.submit();
                }

                Text {
                    text: root.busy ? "Stop" : "Send"
                    color: Theme.bg

                    font.family: Theme.fontUi
                    font.pointSize: 9
                    font.bold: true
                }
            }
        }
    }
}
