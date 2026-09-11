// Media pill, over Quickshell.Services.Mpris.
//
// Nothing surfaced MPRIS anywhere in this tree before this file: no waybar
// module, no eww widget, nothing. A player controlled from the terminal or
// a browser tab had no bar presence at all, unlike every other piece of
// session state (battery, network, volume) this shell already shows.
//
// Hidden entirely when nothing on the session bus is an MPRIS player, the
// same way Battery.qml hides on a machine with no battery: an idle desktop
// has nothing to say about music and should not reserve a capsule to say
// it. media.js's activePlayer() picks which player among possibly several
// this pill speaks for.
//
// OSD integration for track changes (mentioned as a stretch goal) is not
// wired here: Osd.qml's present() is a plain function on that file's own
// Scope, not exposed through shell.qml to any sibling feature, and piping a
// player's trackChanged signal through it would mean growing Osd.qml's own
// surface for a feature that already has a bar pill saying the same thing.
// Not "cheap" by this file's own read, so left alone.
//
// One MouseArea per control rather than Pill's own `interactive`, the same
// choice Tray.qml made for its per-icon click handling: `interactive`
// enables a single MouseArea over the whole capsule, which would swallow a
// click meant for one specific button before it ever reached it.
import QtQuick
import Quickshell.Services.Mpris
import "media.js" as MediaMath
import ".."
import "../common"

Pill {
    id: root

    readonly property var players: Mpris.players.values

    readonly property var player: MediaMath.activePlayer(root.players)

    visible: root.player !== null

    readonly property string label: MediaMath.label(root.player?.trackTitle ?? "", root.player?.trackArtist ?? "")

    Text {
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(implicitWidth, Theme.barTitleMaxWidth)

        text: `${MediaMath.GLYPH_MUSIC} ${root.label}`
        color: Theme.fg

        font.family: Theme.fontUi
        font.pixelSize: Theme.barFontSize
        font.bold: true

        elide: Text.ElideRight
        maximumLineCount: 1
    }

    Text {
        anchors.verticalCenter: parent.verticalCenter

        visible: root.player?.canGoPrevious ?? false
        text: MediaMath.GLYPH_PREVIOUS
        color: Theme.fg

        font.family: Theme.fontUi
        font.pixelSize: Theme.barFontSize

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.player?.previous()
        }
    }

    Text {
        anchors.verticalCenter: parent.verticalCenter

        visible: root.player?.canTogglePlaying ?? false
        text: MediaMath.playPauseGlyph(root.player?.isPlaying ?? false)
        color: Theme.fg

        font.family: Theme.fontUi
        font.pixelSize: Theme.barFontSize

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.player?.togglePlaying()
        }
    }

    Text {
        anchors.verticalCenter: parent.verticalCenter

        visible: root.player?.canGoNext ?? false
        text: MediaMath.GLYPH_NEXT
        color: Theme.fg

        font.family: Theme.fontUi
        font.pixelSize: Theme.barFontSize

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.player?.next()
        }
    }
}
