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
// exits) rather than anything read back off Quickshell's Process.running.
// Nothing here, or in Picker.qml, assumes a particular ordering between
// Process's own `running` and `exited`.
function nextApply(busy, queue) {
    if (busy || queue.length === 0)
        return { entry: null, queue: queue };
    return { entry: queue[0], queue: queue.slice(1) };
}

// flushPendingOutputRecords()'s own decision, pulled out the same way
// nextApply() was: given whatever recordOutputState() queued while
// outputStateFile's first load attempt was still unresolved, what should
// actually get written (null if nothing was queued) and what the queue
// becomes afterward (always empty, since everything queued flushes in one
// merge, not one record at a time). Exists so the double-fire safety
// flushPendingOutputRecords() promises is a property of this function,
// not something only true by construction: a second call, from whichever
// of onLoaded/onLoadFailed did not resolve first, finds nothing left to
// flush because draining an already-empty queue has to return null, and
// that is exactly what running this twice in a row does.
function drainPending(queue) {
    if (queue.length === 0)
        return { records: null, queue: queue };
    return { records: queue, queue: [] };
}

// One record's on-disk shape: config.rs's OutputOverride, whose three
// fields are all `#[serde(default, skip_serializing_if = "Option::is_none")]`,
// present-and-meaningful or entirely absent, never null and never an
// empty string. A wallpaper apply always has a real path/mode/fillColor,
// so this rarely drops anything in practice; it exists so a future caller
// that only knows a subset can still write a valid partial entry, and so
// this never accidentally writes a key whose value is "".
function outputEntry(record) {
    const entry = {};
    if (record.path)
        entry.path = record.path;
    if (record.mode)
        entry.mode = record.mode;
    // fill_color, not fillColor: the on-disk field is config.rs's own
    // OutputOverride::fill_color, serde's default snake_case rename of
    // the Rust field name. Every other function here trades in the
    // app's own camelCase fillColor; this is the one place that name
    // crosses over to the file's own naming.
    if (record.fillColor)
        entry.fill_color = record.fillColor;
    return entry;
}

// config.rs's State: `{ outputs: BTreeMap<String, OutputOverride> }`, the
// output name as the map KEY rather than a field inside the value.
// `outputs` here is that map (not the `{ outputs: ... }` envelope; the
// caller adds that once, at the file boundary), so every function in this
// file trades in the map directly.
//
// A BTreeMap serialises with its keys sorted; this sorts on every merge
// so two writes of the same data produce byte-identical JSON rather than
// churning a diff on insertion order alone.
//
// Each record fully replaces the named output's entry. A wallpaper apply
// is a single "this output is now this path/mode/fillColor" event, not a
// set of independent field patches, so an existing entry for a name in
// `records` is discarded wholesale rather than merged field-by-field. An
// entry whose name is absent from `records` (a disconnected output, or
// simply not part of this apply) is carried over untouched.
function mergeOutputState(existingOutputs, records) {
    const merged = Object.assign({}, existingOutputs || {});
    for (const record of records)
        merged[record.name] = outputEntry(record);

    const sorted = {};
    for (const name of Object.keys(merged).sort())
        sorted[name] = merged[name];
    return sorted;
}

// config.rs's effective_output, minus the declarative config.outputs layer
// this port never gained. Only the runtime-state half survives, so a
// field falls back the moment it is missing (this port never writes null
// or ""; see outputEntry(); but a hand-edited file could, and a falsy
// check treats that the same as absent) rather than checking a second,
// declarative source first.
function effectiveOutput(outputs, name) {
    const found = outputs && outputs[name];
    return {
        path: (found && found.path) || "",
        mode: (found && found.mode) || "fill",
        fillColor: (found && found.fill_color) || DEFAULT_COLOR
    };
}

// Whether `name` has a record at all. effectiveOutput()'s own fallback
// triple cannot answer this, since a real record of exactly fill/
// DEFAULT_COLOR is indistinguishable from no record once both have gone
// through the same fallback. cycleOutput() needs the distinction: landing
// on an output nothing has ever been applied to must leave the user's
// live mode/colour cycling alone rather than stomping it with a fallback
// that was never actually chosen for that output.
function hasOutputRecord(outputs, name) {
    return !!(outputs && Object.prototype.hasOwnProperty.call(outputs, name));
}

// app.rs's restore(): every output that has ever had a wallpaper applied
// gets its OWN stored path/mode/fillColor back, in `outputNames`' order,
// not the current grid selection replayed onto everything. An output with
// no recorded path (never applied to by name) is left out rather than
// restoring an empty apply.
function restoreEntries(outputs, outputNames) {
    const entries = [];
    for (const name of outputNames) {
        const effective = effectiveOutput(outputs, name);
        if (effective.path.length > 0)
            entries.push({ name: name, path: effective.path, mode: effective.mode, fillColor: effective.fillColor });
    }
    return entries;
}
