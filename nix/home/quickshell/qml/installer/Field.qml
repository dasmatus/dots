// A single-line entry field, styled after Settings.qml's text row (the same
// Theme.bgDark fill and Theme.border outline) so the installer does not grow
// a second text-field look the desktop settings form doesn't already have.
//
// Backspace/typing/cursor movement are TextInput's own native keyboard
// handling — nothing here reimplements them, which is how every screen stays
// reachable by keyboard alone without each one hand-rolling char-by-char
// editing the way app.rs's `input.push(c)` / `input.pop()` had to for a raw
// terminal.
import QtQuick
import ".."

Rectangle {
    id: root

    property alias text: input.text
    property bool masked: false
    readonly property alias input: input

    signal accepted()
    signal escaped()

    implicitHeight: 44
    radius: 6
    color: Theme.bgDark
    border.width: 1
    border.color: input.activeFocus ? Theme.accent : Theme.border

    function focusInput() {
        input.forceActiveFocus();
    }

    TextInput {
        id: input

        x: 12
        y: 0
        width: parent.width - 24
        height: parent.height

        color: Theme.fg
        font.family: Theme.fontMono
        font.pixelSize: Theme.fontSize

        echoMode: root.masked ? TextInput.Password : TextInput.Normal
        verticalAlignment: TextInput.AlignVCenter
        clip: true
        selectByMouse: true
        selectionColor: Theme.accent
        selectedTextColor: Theme.bg

        Keys.onReturnPressed: root.accepted()
        Keys.onEnterPressed: root.accepted()
        Keys.onEscapePressed: root.escaped()
    }
}
