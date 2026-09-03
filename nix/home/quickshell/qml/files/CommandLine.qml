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

        if (root.mode !== "")
            input.forceActiveFocus();
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
    // again on the way back to filtering.
    function beginPrompt(seed: string): void {
        input.text = seed;
        input.selectAll();
        input.forceActiveFocus();
    }

    function clear(): void {
        input.text = "";
        root.query = "";
        root.current = 0;

        // Hand focus back explicitly. The TextInput took it imperatively
        // when the line opened, and a hidden item that is still its
        // FocusScope's focused child swallows every key the scope would
        // otherwise route to the `:` catcher.
        input.focus = false;
    }
}
