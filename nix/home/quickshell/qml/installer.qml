// Entry point for the LiveISO installer, run by the ISO's cage session
// rather than by home-manager's Hyprland one.
//
// A second root, not a mode flag on shell.qml, because the two have nothing
// in common at runtime: cage gives a single output and no window manager to
// query, so every Hyprland import shell.qml relies on for per-monitor bars
// and workspace state would resolve to nothing here. Keeping them apart means
// this file only ever has to describe an install session, never the desktop
// bar it will never sit next to.
//
// Only QtQuick, Quickshell and the tree root are imported. No Hyprland: cage
// has no workspaces or focused-window signal to read. No `common`: the
// shared Panel component that real screens will draw from is still being
// built elsewhere, so this placeholder is plain QtQuick styled from Theme,
// proving the palette reaches a second root before there is a real screen to
// prove it on.
import QtQuick
import Quickshell
import "."

ShellRoot {
    PanelWindow {
        id: root

        color: Theme.bg

        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }

        Text {
            anchors.centerIn: parent

            text: "installer"
            color: Theme.fg

            font.family: Theme.fontUi
            font.pixelSize: Theme.fontSize * 3
            font.bold: true
        }
    }
}
