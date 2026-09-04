// Applies the Hyprland active/inactive border colors for the current
// wallpaper accent, tint.rs's hyprland_border_commands_for wired to a
// spawned Process instead of a Rust Command.
//
// Named Borders, not Hyprland: a sibling file named Hyprland.qml would
// shadow the `import Quickshell.Hyprland` module for every other file in
// this directory, since QML resolves a local type name before a module
// one.
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "tint.js" as Tint

Item {
    id: root

    // Quickshell.env returns "" for an unset variable (see Icons.qml's own
    // dataHome fallback), not null/undefined, so a bare env() read has to
    // be coerced before it reaches hyprlandBorderCommands: that function's
    // only "skip" test is `his === null || his === undefined`, and an
    // empty string satisfies neither, which would build a border command
    // around an empty instance signature instead of skipping the target.
    function apply(accent, accentDark) {
        const raw = Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE");
        const his = raw && raw.length > 0 ? raw : null;
        const cmds = Tint.hyprlandBorderCommands(his, accent, accentDark);
        if (cmds === null)
            return;

        // One eval call sets both borders (see tint.js's own header); only
        // ever cmds[0] exists.
        proc.command = cmds[0];
        proc.running = true;
    }

    Process {
        id: proc
    }
}
