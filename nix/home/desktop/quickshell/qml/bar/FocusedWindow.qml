// The focused window's icon and title, for this monitor only. The bar's
// last non-capsule module, now a Pill like every other one — Workspaces,
// Network, Battery, Drives, Keymap, Clock, Tray.
//
// waybar did this with separate-outputs=true, meaning each output's bar showed
// that output's focused window rather than the globally focused one. Reading
// the monitor's own active workspace preserves that: an unfocused monitor
// still names what is on it instead of going blank or echoing the other
// screen.
//
// Icon and title are Pill's own direct children rather than wrapped in a
// second RowLayout: Pill.qml's internal Row only forbids the anchors that
// would fight its own x-positioning (left, right, horizontalCenter, fill,
// centerIn — see Qt's own Row docs), and verticalCenter is not one of them,
// so centring the icon and the differently-tall title against each other
// still works with a plain anchor, the same way it needed one before this
// module used RowLayout instead of Row for exactly that reason.
//
// Hidden entirely when no window is focused, the same way Battery.qml hides
// itself with no battery to show. The Text used to render Theme.muted with
// no toplevel, which read as empty space; an empty *capsule* floating in the
// bar's centre would be worse than that, so the whole Pill goes invisible
// instead.
//
// Elision is by width, not by waybar's max-length=60 character count. Sixty
// characters of "IIII" and sixty of "MMMM" are not the same amount of bar, and
// the centre module is the one that shoves the others around when it guesses
// wrong. The width arithmetic itself lives in focusedwindow.js — see that
// file's own header for why it isn't inline here.
import QtQuick
import Quickshell
import "focusedwindow.js" as FocusedWindowMath
import ".."
import "../common"

Pill {
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

    readonly property string iconSource: root.entry?.icon ? Quickshell.iconPath(root.entry.icon, true) : ""

    readonly property bool hasIcon: root.iconSource !== ""

    readonly property int titleMaxWidth: FocusedWindowMath.availableTitleWidth(Theme.barTitleMaxWidth, Theme.barPillPadding, Theme.barIconSize, root.hasIcon)

    visible: root.toplevel !== null

    Image {
        anchors.verticalCenter: parent.verticalCenter

        width: Theme.barIconSize
        height: Theme.barIconSize

        source: root.iconSource
        visible: root.hasIcon

        sourceSize.width: Theme.barIconSize
        sourceSize.height: Theme.barIconSize
    }

    Text {
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(implicitWidth, root.titleMaxWidth)

        text: root.toplevel?.title ?? ""
        color: Theme.fg

        font.family: Theme.fontUi
        font.pixelSize: Theme.barFontSize
        font.bold: true

        elide: Text.ElideRight
        maximumLineCount: 1
    }
}
