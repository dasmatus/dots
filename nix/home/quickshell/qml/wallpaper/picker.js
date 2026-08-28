// Picker.qml's key-driven state transitions, ported from rust/wallpaper-
// tui's App::handle_key and config.rs (both deleted at aa995a4). Kept out
// of the component, the same way arrange.js and accent.js are, so
// tests/qml/tst_picker.qml can exercise cycling and grid-cursor arithmetic
// directly, with no window, no Process and no live GridView anywhere near
// the test.
.pragma library

// Verbatim from the deleted crate's config.rs, same order: both are cycled
// through in exactly this sequence.
const MODES = ["fill", "stretch", "fit", "center", "tile"];

const COLOR_PALETTE = ["#d2a1a1", "#1a1b26", "#000000", "#ffffff", "#7aa2f7", "#bb9af7", "#9ece6a", "#f7768e"];

const DEFAULT_COLOR = "#d2a1a1";

// Advances `current` to the next entry of `list`, wrapping past the end.
// `indexOf` reports -1 for a value absent from `list`, which lands on the
// first entry via `-1 + 1 === 0` rather than needing a separate branch for
// "current isn't even in here".
function cycleThrough(current, list) {
    return list[(list.indexOf(current) + 1) % list.length];
}

function cycleMode(current) {
    return cycleThrough(current, MODES);
}

function cycleColor(current) {
    return cycleThrough(current, COLOR_PALETTE);
}

// "*" (every output) cycles first, then each declared output by name.
// config.rs paired a `current_output` index with an `outputs` list built
// from auto-detection plus config entries; this port has no daemon-side
// output detection, so the caller hands the live list in instead.
function cycleOutput(current, outputs) {
    return cycleThrough(current, ["*"].concat(outputs));
}

// awww's --fill-color wants the bare hex; the palette above (and every
// other colour value in this repo) carries the leading '#'. Same trim
// config.rs's own `trim_start_matches('#')` did.
function fillColorArg(color) {
    return color.startsWith("#") ? color.slice(1) : color;
}

// Clamps a grid cursor move to a valid index rather than wrapping like the
// TUI's flat wallpaper list did: GridView has rows, and wrapping a
// row-move (delta === +-columnsPerRow) would jump the cursor across the
// grid instead of stopping it at the top or bottom edge.
function gridMove(index, delta, count) {
    if (count <= 0)
        return index;
    return Math.min(count - 1, Math.max(0, index + delta));
}
