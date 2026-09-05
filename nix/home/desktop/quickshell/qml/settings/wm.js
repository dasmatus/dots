// Pure hyprctl-keyword arithmetic behind the window-manager page's live-apply
// path — split out for the same reason pages.js and search.js are (see
// their own headers): Settings.qml reaches Quickshell.Io's Process, which
// qmltestrunner cannot load (tests/README.md), so the one part of "what do I
// run to apply this row" worth unit-testing at all has to live somewhere
// that isn't inside it.
.pragma library

// Which `hyprctl keyword` target a window-manager settings key maps to, and
// whether that target is one of Hyprland's own boolean-as-0/1 nodes rather
// than a bare number or string — see the task brief's own table.
// wmFollowMouse is the one field where the settings side stores a bool but
// Hyprland's own config takes an int (0/1/2/3 in general); the settings
// panel only ever offers on/off, so true/false collapse to Hyprland's own
// default 1/0 here, matching nix/system/defaults.nix's comment on the key.
const HYPR_TARGETS = {
    wmGapsIn: {
        target: "general:gaps_in",
        boolAsInt: false
    },
    wmGapsOut: {
        target: "general:gaps_out",
        boolAsInt: false
    },
    wmBorderSize: {
        target: "general:border_size",
        boolAsInt: false
    },
    wmFollowMouse: {
        target: "input:follow_mouse",
        boolAsInt: true
    },
    wmAnimations: {
        target: "animations:enabled",
        boolAsInt: true
    },
    wmLayout: {
        target: "general:layout",
        boolAsInt: false
    }
};

// The `hyprctl keyword <target> <value>` argv for one changed key, or null
// for a key this shell does not live-apply — every non-WM key, and any WM
// key this table has not been taught yet. Returning null rather than
// throwing is what lets a caller run this unconditionally after every
// successful persist, one shared path for both WM and non-WM rows, rather
// than a second branch above it that has to already know which is which.
function hyprctlArgs(key, value) {
    const entry = HYPR_TARGETS[key];
    if (!entry)
        return null;

    const rendered = entry.boolAsInt ? (value ? "1" : "0") : `${value}`;
    return ["hyprctl", "keyword", entry.target, rendered];
}
