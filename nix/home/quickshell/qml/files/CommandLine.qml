// The `:` command line along the bottom edge, with its matches listed
// above it. Vim's command line is the model: a prefix character opens it,
// what you type filters, Enter runs, Esc abandons.
//
// It carries the prompts too. Rename, New Folder and the trash
// confirmation all need one line of input or one yes/no, and giving them
// this line instead of their own popup means `promptMode`'s existing state
// machine keeps working and there is exactly one place on screen that ever
// asks the user for text.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import "commands.js" as Commands
import "../common"
import ".."

Rectangle {
    id: root

    // "" when closed, "command" while filtering, or one of Files.qml's own
    // promptMode values once a command that needs input has been chosen.
    required property string mode
    required property var entries
    required property var selection
    required property var clipboard
    required property bool showHidden

    property string query: ""
    property int current: 0

    // Exposed the way common/Field.qml exposes its own, so
    // tst_files_cmdline_focus.qml can read the field's focus and text
    // without a findChild by objectName. `query` only tracks the filtering
    // modes; a rename or mkdir prompt lives in the field's text alone.
    readonly property alias input: input

    readonly property bool prompting: root.mode === "rename" || root.mode === "mkdir"
    readonly property bool confirming: root.mode === "trash-confirm"
    readonly property bool listing: root.mode === "command" || root.mode === "search"

    readonly property var rows: {
        if (root.mode === "command")
            return Commands.actionsFor(root.query, root.selection, root.clipboard, root.showHidden);

        if (root.mode === "search")
            return Commands.entriesFor(root.query, root.entries);

        return [];
    }

    signal activated(var row)
    signal submitted(string text)
    signal cancelled()

    visible: root.mode !== ""
    color: Theme.bgDarker
    implicitHeight: list.implicitHeight + line.implicitHeight

    // Only the top corners: the line is flush with the window's bottom
    // edge, and rounding there would show the window ground through two
    // notches.
    topLeftRadius: Theme.filesRadius
    topRightRadius: Theme.filesRadius

    onModeChanged: {
        if (root.listing) {
            root.query = "";
            root.current = 0;
        }
    }

    function move(delta: int): void {
        if (root.rows.length === 0)
            return;

        root.current = Math.max(0, Math.min(root.current + delta, root.rows.length - 1));
    }

    function accept(): void {
        if (root.listing) {
            if (root.rows.length > 0)
                root.activated(root.rows[root.current]);

            return;
        }

        root.submitted(input.text);
    }

    Rectangle {
        anchors.top: parent.top
        width: parent.width
        height: 1
        color: Theme.border
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        ListView {
            id: list

            Layout.fillWidth: true
            Layout.preferredHeight: implicitHeight

            // Caps how tall the line can grow. A match list that fills the
            // window hides the directory you are choosing from.
            implicitHeight: Math.min(root.rows.length, 8) * Theme.filesRowHeight
            visible: root.listing
            clip: true
            currentIndex: root.current

            model: root.rows

            delegate: Rectangle {
                id: hit

                required property var modelData
                required property int index

                readonly property bool isCurrent: hit.index === root.current

                width: ListView.view.width
                height: Theme.filesRowHeight
                color: hit.isCurrent ? Theme.accent : "transparent"

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.filesPadding
                    anchors.rightMargin: Theme.filesPadding
                    spacing: 0

                    Text {
                        Layout.preferredWidth: Theme.filesIconColumn

                        text: hit.modelData.glyph
                        // icons.js and palette.js hand back a Theme property
                        // name, so the lookup is the property access rather
                        // than a switch repeated in every consumer.
                        color: hit.isCurrent ? Theme.bg : Tokens.colourOf(hit.modelData.colour)
                        font.family: Theme.fontUi
                        font.pixelSize: Theme.filesIconSize
                    }

                    Text {
                        text: hit.modelData.title
                        color: hit.isCurrent ? Theme.bg : Theme.fg
                        font.family: Theme.fontUi
                        font.pixelSize: Theme.fontSize
                    }

                    Item {
                        Layout.fillWidth: true
                    }

                    Text {
                        text: hit.modelData.subtitle
                        color: hit.isCurrent ? Theme.bg : Theme.muted
                        font.family: Theme.fontMono
                        font.pixelSize: Theme.fontSize
                        elide: Text.ElideLeft
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        root.current = hit.index;
                        root.activated(hit.modelData);
                    }
                }
            }
        }

        RowLayout {
            id: line

            Layout.fillWidth: true
            Layout.leftMargin: Theme.filesPadding
            Layout.rightMargin: Theme.filesPadding
            implicitHeight: Theme.filesCommandHeight

            spacing: 8

            // The prefix says which line this is, exactly as vim's does:
            // `/` searches the directory, `:` runs a command, and a prompt
            // shows what it is about to do instead.
            Text {
                text: {
                    if (root.confirming)
                        return "\u{F0A79}";

                    return root.mode === "search" ? "/" : ":";
                }
                color: root.confirming ? Theme.red : Theme.accent
                font.family: Theme.fontMono
                font.pixelSize: Theme.fontSize
                font.bold: true
            }

            Text {
                text: {
                    if (root.confirming)
                        return `Trash "${root.query}"?  Enter to confirm, Esc to cancel`;

                    if (root.mode === "rename")
                        return "Rename to";

                    if (root.mode === "mkdir")
                        return "New folder";

                    return "";
                }
                color: root.confirming ? Theme.red : Theme.muted
                font.family: Theme.fontUi
                font.pixelSize: Theme.fontSize
                visible: text !== ""
            }

            TextInput {
                id: input

                Layout.fillWidth: true

                color: Theme.fg
                font.family: Theme.fontMono
                font.pixelSize: Theme.fontSize
                verticalAlignment: TextInput.AlignVCenter
                selectByMouse: true
                selectionColor: Theme.accent
                selectedTextColor: Theme.bg

                // The confirmation takes no text, so its caret would be a
                // cursor blinking at nothing to type.
                visible: !root.confirming

                // Bound, not taken with forceActiveFocus() when the mode
                // changes. The imperative version was correct in itself and
                // still lost every `:` and `/`: Files.qml's openCmdline sets
                // promptMode and then calls clear(), and clear() ended by
                // dropping focus again, so the line came up with nothing in
                // the window focused at all and swallowed everything typed
                // into it. A binding cannot be undone by the statement after
                // the one that armed it. It is also the same shape the
                // `catcher` item in Files.qml already uses for the opposite
                // half of this handover, and the three bindings — catcher's
                // closed state, this one, and the confirm item's below —
                // are mutually exclusive, so exactly one holds focus.
                focus: root.mode !== "" && !root.confirming

                onTextChanged: {
                    if (root.listing) {
                        root.query = text;
                        root.current = 0;
                    }
                }

                Keys.onDownPressed: root.move(1)
                Keys.onUpPressed: root.move(-1)
                Keys.onReturnPressed: root.accept()
                Keys.onEnterPressed: root.accept()
                Keys.onEscapePressed: root.cancelled()
            }

            // The confirmation still has to catch Enter and Esc, and the
            // TextInput that normally would is hidden for it.
            Item {
                Layout.fillWidth: true
                visible: root.confirming
                focus: root.confirming

                Keys.onReturnPressed: root.accept()
                Keys.onEnterPressed: root.accept()
                Keys.onEscapePressed: root.cancelled()
            }
        }
    }

    // Seeds the field when a prompt takes over the line, and clears it
    // again on the way back to filtering. Neither one touches focus: the
    // TextInput's `focus` binding above already follows the mode, and both
    // of these are called right after a mode change by callers that would
    // otherwise be undoing it.
    function beginPrompt(seed: string): void {
        input.text = seed;
        input.selectAll();
    }

    function clear(): void {
        input.text = "";
        root.query = "";
        root.current = 0;
    }
}
