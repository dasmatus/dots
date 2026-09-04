// The input end of the pane: a prompt field, a backend and model picker, an
// attachment row, and one button that is Send while the thread is idle and
// Stop while a turn runs.
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
//
// ATTACHMENTS, AND WHY THIS SIDE ONLY WRITES SCRATCH. Three ways in: a drop, a
// paste, and a region capture. All three end with a file somewhere and a path
// in `attachments`, and none of them puts that file where it will be kept. The
// daemon copies every attachment into the conversation's own directory when the
// send is recorded, because the path in a persisted user_message has to outlive
// what this side wrote. So captures and pastes go to $XDG_RUNTIME_DIR/dots-ask,
// which the spec's own send example names and which the tmpfs empties at
// logout, and a dropped file is passed by its real path and never touched.
//
// grim, slurp and wl-paste are named bare and come from PATH. nix/home/ask.nix
// puts all three on it under the same dots.ai gate that installs the daemon, so
// a machine with the pane has them and a machine without it has neither.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import ".."
import "../common"

Rectangle {
    id: root

    property var backends: []
    property string backend: ""
    property string model: ""
    property bool busy: false

    // What will ride the next send: rows of {path, mime, name}. Cleared by
    // submit(), because an attachment belongs to the message it was staged
    // for and silently carrying one into the next message is the kind of
    // surprise that sends a screenshot to the wrong thread.
    property var attachments: []

    readonly property alias text: input.text

    signal submitted(string text, var attachments)
    signal interrupted
    signal backendPicked(string id)
    signal modelPicked(string name)

    // Where a capture or a paste lands before the daemon takes it. Runtime
    // rather than state or data: this side's copy is scratch, and the tmpfs
    // clearing it at logout is the correct lifetime for a file the daemon has
    // already copied somewhere durable.
    readonly property string scratchDir: `${Quickshell.env("XDG_RUNTIME_DIR")}/dots-ask`

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
    border.color: dropArea.containsDrag ? Theme.accent : (input.activeFocus ? Theme.accent : Theme.border)

    function focusInput(): void {
        input.forceActiveFocus();
    }

    function submit(): void {
        const body = input.text.trim();
        if (body === "" && root.attachments.length === 0)
            return;

        const staged = root.attachments;

        input.text = "";
        root.attachments = [];
        root.submitted(body, staged);
    }

    // Stages one file. Deduplicated by path, because dropping the same file
    // twice is a slip rather than a request to send it twice, and because the
    // daemon would otherwise copy it in under two names.
    function attachPath(path: string, mime: string): void {
        for (const existing of root.attachments) {
            if (existing.path === path)
                return;
        }

        const at = path.lastIndexOf("/");
        root.attachments = root.attachments.concat([
            {
                path: path,
                mime: mime,
                name: at === -1 ? path : path.slice(at + 1)
            }
        ]);
    }

    function removeAttachment(path: string): void {
        root.attachments = root.attachments.filter(entry => entry.path !== path);
    }

    // Guesses a media type from the extension, and leaves it empty when it
    // cannot. Empty is honest: the daemon fills one in from the extension
    // itself and refuses to inline anything no provider accepts, so a wrong
    // guess here would be worse than none.
    function mimeOf(path: string): string {
        const lower = path.toLowerCase();
        if (lower.endsWith(".png"))
            return "image/png";
        if (lower.endsWith(".jpg") || lower.endsWith(".jpeg"))
            return "image/jpeg";
        if (lower.endsWith(".gif"))
            return "image/gif";
        if (lower.endsWith(".webp"))
            return "image/webp";
        return "";
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

    // A region capture. `grim -g "$(slurp)"` is the two-program form the brief
    // names; hyprshot is not used here because it saves to the pictures folder
    // and notifies, both of which are wrong for a file that exists only to be
    // attached.
    //
    // One shell rather than two Processes because the capture is one pipeline:
    // slurp has to run, the user has to drag, and only then does grim get a
    // geometry. Splitting it would mean holding slurp's stdout across a signal
    // for no gain. `set -e` so a cancelled slurp, which exits non-zero, leaves
    // no zero-byte PNG behind for the daemon to refuse.
    function capture(): void {
        const target = `${root.scratchDir}/cap-${Date.now()}.png`;
        grab.pending = target;
        grab.command = ["sh", "-c", `set -e; mkdir -p ${root.scratchDir}; grim -g "$(slurp)" ${target}`];
        grab.running = true;
    }

    // A pasted image. wl-paste writes the clipboard's image/png to a file and
    // exits non-zero when the clipboard holds no image, which is what makes
    // this safe to fire on every Ctrl+V: a text paste fails here and the
    // TextEdit's own handler has already inserted the text.
    function pasteImage(): void {
        const target = `${root.scratchDir}/paste-${Date.now()}.png`;
        grab.pending = target;
        grab.command = ["sh", "-c", `set -e; mkdir -p ${root.scratchDir}; wl-paste --type image/png > ${target}`];
        grab.running = true;
    }

    // One Process for both, since neither can be running while the other is:
    // slurp holds the pointer and a paste is instant.
    Process {
        id: grab

        property string pending: ""

        // qmllint disable signal-handler-parameters
        onExited: (exitCode, exitStatus) => {
            if (exitCode === 0 && grab.pending !== "")
                root.attachPath(grab.pending, "image/png");

            grab.pending = "";
        }
        // qmllint enable signal-handler-parameters
    }

    // Dropped files. Quickshell's surfaces accept drags like any QtQuick item,
    // and a drop carries file:// urls that have to be turned back into paths
    // before they can go on the wire: the schema's `path` is a filesystem
    // path, not a url, and the daemon opens it with fs::metadata.
    DropArea {
        id: dropArea

        anchors.fill: parent

        onDropped: drop => {
            if (!drop.hasUrls)
                return;

            for (const url of drop.urls) {
                const path = String(url).startsWith("file://") ? decodeURIComponent(String(url).slice(7)) : String(url);
                root.attachPath(path, root.mimeOf(path));
            }
            drop.accept();
        }
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
                //
                // Ctrl+V is NOT accepted here. It fires the image probe and
                // then falls through to the TextEdit's own paste, because a
                // clipboard can hold both and swallowing the key would break
                // pasting text to gain pasting images. wl-paste exits non-zero
                // when there is no image, which is what makes firing it on
                // every paste harmless.
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_V && (event.modifiers & Qt.ControlModifier)) {
                        root.pasteImage();
                        return;
                    }

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

        // Staged attachments, as chips that can be taken back off.
        //
        // A Flow rather than a RowLayout: four screenshots overflow a 560px
        // pane, and a row would push the send button off the edge rather than
        // wrap. Hidden entirely when nothing is staged, so the composer keeps
        // its usual height for the messages that carry no file.
        Flow {
            Layout.fillWidth: true

            visible: root.attachments.length > 0
            spacing: 6

            Repeater {
                model: root.attachments

                delegate: Pill {
                    id: chip

                    required property var modelData

                    interactive: true
                    color: Theme.bgDarker

                    // Clicking the chip takes it off. There is no separate
                    // hit target for the ✕ because the whole chip is small
                    // and a two-target pill at this size is a miss waiting to
                    // happen; the ✕ is the affordance, not the button.
                    onClicked: root.removeAttachment(chip.modelData.path)

                    Row {
                        spacing: 6

                        Text {
                            text: chip.modelData.name
                            textFormat: Text.PlainText
                            color: Theme.fgDark

                            font.family: Theme.fontMono
                            font.pointSize: 9
                        }

                        Text {
                            text: "✕"
                            color: Theme.muted

                            font.family: Theme.fontUi
                            font.pointSize: 9
                        }
                    }
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
            textFormat: Text.PlainText
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

            // Region capture. Disabled while one is already running, because
            // slurp holds the pointer and a second one would sit behind the
            // first waiting for a drag that cannot reach it.
            Pill {
                interactive: !grab.running
                color: Theme.bgDarker

                onClicked: root.capture()

                Text {
                    text: grab.running ? "capturing" : "capture"
                    color: grab.running ? Theme.muted : Theme.fgDark

                    font.family: Theme.fontUi
                    font.pointSize: 9
                }
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
