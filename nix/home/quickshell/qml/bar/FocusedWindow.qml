// The focused window's icon and title, for this monitor only.
//
// waybar did this with separate-outputs=true, meaning each output's bar showed
// that output's focused window rather than the globally focused one. Reading
// the monitor's own active workspace preserves that: an unfocused monitor
// still names what is on it instead of going blank or echoing the other
// screen.
//
// RowLayout rather than Row because the icon and the text are different
// heights and need centring against each other. Items inside a plain Row
// cannot use anchors, so there is no way to centre them there without the
// positioner complaining.
//
// Elision is by width, not by waybar's max-length=60 character count. Sixty
// characters of "IIII" and sixty of "MMMM" are not the same amount of bar, and
// the centre module is the one that shoves the others around when it guesses
// wrong.
import QtQuick
import QtQuick.Layouts
import Quickshell
import ".."

RowLayout {
    id: root

    required property var monitor

    readonly property var toplevel: {
        const workspace = root.monitor?.activeWorkspace;
        if (!workspace)
            return null;

        return workspace.toplevels.values.find(t => t.activated) ?? null;
    }

    readonly property string appId: root.toplevel?.wayland?.appId ?? ""

    readonly property var entry: root.appId === "" ? null : DesktopEntries.byId(root.appId)

    spacing: 8

    Image {
        Layout.alignment: Qt.AlignVCenter
        Layout.preferredWidth: Theme.barIconSize
        Layout.preferredHeight: Theme.barIconSize

        source: root.entry?.icon ? Quickshell.iconPath(root.entry.icon, true) : ""
        visible: source !== ""

        sourceSize.width: Theme.barIconSize
        sourceSize.height: Theme.barIconSize
    }

    Text {
        Layout.alignment: Qt.AlignVCenter
        Layout.maximumWidth: Theme.barTitleMaxWidth

        text: root.toplevel?.title ?? ""
        color: root.toplevel ? Theme.fg : Theme.muted

        font.family: Theme.fontUi
        font.pixelSize: Theme.barFontSize
        font.bold: true

        elide: Text.ElideRight
        maximumLineCount: 1
    }
}
