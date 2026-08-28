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

// The apply queue's own decision, pulled out of Picker.qml so it is
// testable without a live Process: given whether an awww invocation is
// already running and the pending queue, is there anything to start next,
// and what is left in the queue afterwards. `busy` is a flag the caller
// tracks itself (set the moment a Process starts, cleared the moment it
// exits) rather than anything read back off Quickshell's Process.running —
// nothing here, or in Picker.qml, assumes a particular ordering between
// Process's own `running` and `exited`.
function nextApply(busy, queue) {
    if (busy || queue.length === 0)
        return { entry: null, queue: queue };
    return { entry: queue[0], queue: queue.slice(1) };
}

// Upserts one record per {name, path, mode, fillColor} in `records` into
// `existingRoot`'s `entries`, keyed by name — arrange.js's own
// mergedOverrides, minus the position-only partial update, since a
// wallpaper apply always replaces every field of an output's record at
// once. An entry whose name is absent from `records` (a disconnected
// output, or simply not part of this apply) is carried over untouched.
function mergeOutputState(existingRoot, records) {
    const byName = {};
    const existingEntries = (existingRoot && existingRoot.entries) || [];
    for (const entry of existingEntries) {
        if (entry.name)
            byName[entry.name] = Object.assign({}, entry);
    }
    for (const record of records) {
        const entry = byName[record.name] || { name: record.name };
        entry.path = record.path;
        entry.mode = record.mode;
        entry.fillColor = record.fillColor;
        byName[record.name] = entry;
    }
    return { entries: Object.values(byName) };
}

// config.rs's effective_output, minus the declarative config.outputs layer
// this port never gained — only the runtime-state half survives, so a
// field falls back the moment it is missing or empty rather than checking
// a second, declarative source first.
function effectiveOutput(outputState, name) {
    const entries = (outputState && outputState.entries) || [];
    const found = entries.find(e => e.name === name);
    return {
        path: (found && found.path) || "",
        mode: (found && found.mode) || "fill",
        fillColor: (found && found.fillColor) || DEFAULT_COLOR
    };
}

// app.rs's restore(): every output that has ever had a wallpaper applied
// gets its OWN stored path/mode/fillColor back, in `outputNames`' order —
// not the current grid selection replayed onto everything. An output with
// no recorded path (never applied to by name) is left out rather than
// restoring an empty apply.
function restoreEntries(outputState, outputNames) {
    const entries = [];
    for (const name of outputNames) {
        const effective = effectiveOutput(outputState, name);
        if (effective.path.length > 0)
            entries.push({ name: name, path: effective.path, mode: effective.mode, fillColor: effective.fillColor });
    }
    return entries;
}
