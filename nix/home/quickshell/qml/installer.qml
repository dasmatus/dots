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
// FloatingWindow, not PanelWindow: Quickshell backs PanelWindow with the
// zwlr_layer_shell_v1 Wayland protocol, and cage does not implement it (its
// compositor only ever calls wlr_xdg_shell_create and wlr_xwayland_create —
// grep cage's source for layer_shell and it comes back empty). A
// PanelWindow root here would never be mapped and the ISO would boot to a
// blank screen. FloatingWindow is Quickshell's xdg-shell toplevel, which
// cage does speak. It needs no anchors: cage maximizes the single toplevel
// it is handed, so width/height below are only the pre-maximize fallback,
// never the on-screen size. Do not change this back to PanelWindow to match
// the rest of the tree — the rest of the tree runs under Hyprland, which
// does implement layer-shell; this file runs under cage, which does not.
//
// Only QtQuick, Quickshell and the tree root are imported. No Hyprland: cage
// has no workspaces or focused-window signal to read. No `common`: the
// shared Panel component is a bordered, padded box meant to float inside a
// PanelWindow (the launcher, the settings form); this root is a full-bleed
// background with no chrome to border, so it styles itself from Theme
// directly. Real install screens land in a later plan.
import QtQuick
import Quickshell
import "."

ShellRoot {
    FloatingWindow {
        color: Theme.bg

        width: 1280
        height: 800

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
