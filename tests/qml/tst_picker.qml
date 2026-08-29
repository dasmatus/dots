// picker.js's pure cycling and grid-cursor math, tested without a live
// Picker.qml — that component reaches Quickshell.Io's Process, which
// qmltestrunner cannot instantiate (see tst_tint_wiring.qml's header for
// the same constraint on the tint targets).
import QtQuick
import QtTest
import "../../nix/home/quickshell/qml/wallpaper/picker.js" as PickerLogic

TestCase {
    name: "Picker"

    // The brief says "verbatim and in this order" for both lists; the
    // cycling tests below only pin four transitions out of thirteen
    // entries between them, which passes just as well with two elements
    // swapped. These pin every element, in order, so a swap fails here
    // even though it would not fail a cycling test.
    function test_MODES_matches_the_deleted_crates_order() {
        const expected = ["fill", "stretch", "fit", "center", "tile"];
        compare(PickerLogic.MODES.length, expected.length);
        for (let i = 0; i < expected.length; i++)
            compare(PickerLogic.MODES[i], expected[i], `MODES[${i}]`);
    }

    function test_COLOR_PALETTE_matches_the_deleted_crates_order() {
        const expected = ["#d2a1a1", "#1a1b26", "#000000", "#ffffff", "#7aa2f7", "#bb9af7", "#9ece6a", "#f7768e"];
        compare(PickerLogic.COLOR_PALETTE.length, expected.length);
        for (let i = 0; i < expected.length; i++)
            compare(PickerLogic.COLOR_PALETTE[i], expected[i], `COLOR_PALETTE[${i}]`);
    }

    function test_DEFAULT_COLOR_is_the_palettes_first_entry() {
        compare(PickerLogic.DEFAULT_COLOR, "#d2a1a1");
    }

    function test_cycleMode_data() {
        return [
            { tag: "steps to the next mode", current: "fill", expected: "stretch" },
            { tag: "wraps from the last mode to the first", current: "tile", expected: "fill" },
            { tag: "a mode absent from the list lands on the first", current: "bogus", expected: "fill" }
        ];
    }

    function test_cycleMode(row) {
        compare(PickerLogic.cycleMode(row.current), row.expected);
    }

    function test_cycleColor_data() {
        return [
            { tag: "steps to the next colour", current: "#d2a1a1", expected: "#1a1b26" },
            { tag: "wraps from the last colour to the first", current: "#f7768e", expected: "#d2a1a1" },
            { tag: "a colour absent from the palette lands on the first", current: "#123456", expected: "#d2a1a1" }
        ];
    }

    function test_cycleColor(row) {
        compare(PickerLogic.cycleColor(row.current), row.expected);
    }

    function test_cycleOutput_data() {
        return [
            { tag: "every output steps to the first named one", current: "*", outputs: ["DP-1", "DP-2"], expected: "DP-1" },
            { tag: "the last named output wraps back to every output", current: "DP-2", outputs: ["DP-1", "DP-2"], expected: "*" },
            { tag: "an output absent from the list lands on every output", current: "HDMI-A-1", outputs: ["DP-1", "DP-2"], expected: "*" },
            { tag: "no declared outputs leaves it on every output", current: "*", outputs: [], expected: "*" }
        ];
    }

    function test_cycleOutput(row) {
        compare(PickerLogic.cycleOutput(row.current, row.outputs), row.expected);
    }

    function test_fillColorArg_data() {
        return [
            { tag: "strips a leading hash", color: "#d2a1a1", expected: "d2a1a1" },
            { tag: "leaves a bare hex alone", color: "d2a1a1", expected: "d2a1a1" }
        ];
    }

    function test_fillColorArg(row) {
        compare(PickerLogic.fillColorArg(row.color), row.expected);
    }

    function test_gridMove_data() {
        return [
            { tag: "moves right within bounds", index: 2, delta: 1, count: 10, expected: 3 },
            { tag: "moves down a row within bounds", index: 2, delta: 4, count: 10, expected: 6 },
            { tag: "clamps at the top edge", index: 0, delta: -4, count: 10, expected: 0 },
            { tag: "clamps at the bottom edge", index: 8, delta: 4, count: 10, expected: 9 },
            { tag: "an empty grid is a no-op", index: 0, delta: 1, count: 0, expected: 0 },
            { tag: "an unselected cursor moves onto the grid", index: -1, delta: 1, count: 10, expected: 0 }
        ];
    }

    function test_gridMove(row) {
        compare(PickerLogic.gridMove(row.index, row.delta, row.count), row.expected);
    }

    function test_nextApply_a_busy_pump_starts_nothing() {
        const queue = [{ path: "/a.png" }, { path: "/b.png" }];
        const decision = PickerLogic.nextApply(true, queue);

        compare(decision.entry, null);
        compare(decision.queue.length, 2);
    }

    function test_nextApply_an_empty_queue_starts_nothing() {
        const decision = PickerLogic.nextApply(false, []);

        compare(decision.entry, null);
        compare(decision.queue.length, 0);
    }

    function test_nextApply_an_idle_pump_takes_the_front_of_the_queue() {
        const queue = [{ path: "/a.png" }, { path: "/b.png" }];
        const decision = PickerLogic.nextApply(false, queue);

        compare(decision.entry.path, "/a.png");
        compare(decision.queue.length, 1);
        compare(decision.queue[0].path, "/b.png");
    }

    function test_drainPending_an_empty_queue_has_nothing_to_flush() {
        const decision = PickerLogic.drainPending([]);

        compare(decision.records, null);
        compare(decision.queue.length, 0);
    }

    function test_drainPending_a_nonEmpty_queue_flushes_everything_and_empties() {
        const queue = [{ name: "DP-1" }, { name: "DP-2" }];
        const decision = PickerLogic.drainPending(queue);

        compare(decision.records.length, 2);
        compare(decision.records[0].name, "DP-1");
        compare(decision.records[1].name, "DP-2");
        compare(decision.queue.length, 0);
    }

    // This is the double-fire safety flushPendingOutputRecords() promises:
    // draining what an earlier drain already emptied must find nothing
    // left, which is the only way a second onLoaded/onLoadFailed firing
    // for the same file can be a no-op rather than a second write. The
    // live probes that motivated this fix could only ever exercise one
    // of loaded/loadFailed per run, never both, so this is the only place
    // that actually establishes it.
    function test_drainPending_draining_an_already_drained_queue_is_a_no_op() {
        const first = PickerLogic.drainPending([{ name: "DP-1" }]);
        const second = PickerLogic.drainPending(first.queue);

        compare(second.records, null);
        compare(second.queue.length, 0);
    }

    // config.rs's State.outputs was a BTreeMap<String, OutputOverride> —
    // an object keyed by output name, not a list with the name inside
    // each entry — so these all exercise that shape directly.
    function test_mergeOutputState_a_fresh_file_gets_one_entry_per_record() {
        const merged = PickerLogic.mergeOutputState(null, [{ name: "DP-1", path: "/a.png", mode: "fill", fillColor: "#d2a1a1" }]);

        compare(Object.keys(merged).length, 1);
        compare(merged["DP-1"].path, "/a.png");
        compare(merged["DP-1"].mode, "fill");
        // fill_color, snake_case, matching OutputOverride's own field —
        // not fillColor. No `name` key either: DP-1 is the object key.
        compare(merged["DP-1"].fill_color, "#d2a1a1");
        compare(merged["DP-1"].name, undefined);
    }

    function test_mergeOutputState_a_name_matched_entry_is_fully_replaced() {
        const existingOutputs = { "DP-1": { path: "/old.png", mode: "tile", fill_color: "#000000" } };
        const merged = PickerLogic.mergeOutputState(existingOutputs, [{ name: "DP-1", path: "/new.png", mode: "fit", fillColor: "#ffffff" }]);

        compare(Object.keys(merged).length, 1);
        compare(merged["DP-1"].path, "/new.png");
        compare(merged["DP-1"].mode, "fit");
        compare(merged["DP-1"].fill_color, "#ffffff");
    }

    function test_mergeOutputState_an_entry_absent_from_records_is_left_alone() {
        const existingOutputs = { "DP-9": { path: "/untouched.png", mode: "fill", fill_color: "#d2a1a1" } };
        const merged = PickerLogic.mergeOutputState(existingOutputs, [{ name: "DP-1", path: "/a.png", mode: "fill", fillColor: "#d2a1a1" }]);

        compare(Object.keys(merged).length, 2);
        compare(merged["DP-9"].path, "/untouched.png");
    }

    function test_mergeOutputState_a_wildcard_apply_records_every_name_at_once() {
        const merged = PickerLogic.mergeOutputState(null, [
            { name: "DP-1", path: "/a.png", mode: "fill", fillColor: "#d2a1a1" },
            { name: "DP-2", path: "/a.png", mode: "fill", fillColor: "#d2a1a1" }
        ]);

        compare(Object.keys(merged).length, 2);
    }

    // A BTreeMap<String, _> serialises with its keys sorted; merging
    // records in reverse-alphabetical order must still come out sorted,
    // or the file churns in a diff between two writes of the same data.
    function test_mergeOutputState_sorts_keys_regardless_of_record_order() {
        const merged = PickerLogic.mergeOutputState(null, [
            { name: "DP-2", path: "/b.png", mode: "fill", fillColor: "#d2a1a1" },
            { name: "DP-1", path: "/a.png", mode: "fill", fillColor: "#d2a1a1" }
        ]);

        compare(Object.keys(merged), ["DP-1", "DP-2"]);
    }

    // OutputOverride's fields are all `#[serde(skip_serializing_if =
    // "Option::is_none")]` — omitted, not written as null or "". A record
    // with a falsy field must not add that key to the entry at all.
    function test_mergeOutputState_omits_a_falsy_field_rather_than_writing_it_empty() {
        const merged = PickerLogic.mergeOutputState(null, [{ name: "DP-1", path: "/a.png", mode: "", fillColor: undefined }]);

        compare(merged["DP-1"].path, "/a.png");
        compare("mode" in merged["DP-1"], false);
        compare("fill_color" in merged["DP-1"], false);
    }

    function test_effectiveOutput_data() {
        return [
            { tag: "no state file yet falls back", outputs: null, name: "DP-1", expected: { path: "", mode: "fill", fillColor: PickerLogic.DEFAULT_COLOR } },
            { tag: "an empty outputs map falls back", outputs: {}, name: "DP-1", expected: { path: "", mode: "fill", fillColor: PickerLogic.DEFAULT_COLOR } },
            { tag: "a recorded output returns its own record", outputs: { "DP-1": { path: "/a.png", mode: "tile", fill_color: "#123456" } }, name: "DP-1", expected: { path: "/a.png", mode: "tile", fillColor: "#123456" } },
            { tag: "a differently named entry does not match", outputs: { "DP-2": { path: "/a.png", mode: "tile", fill_color: "#123456" } }, name: "DP-1", expected: { path: "", mode: "fill", fillColor: PickerLogic.DEFAULT_COLOR } },
            { tag: "a matched record with every field omitted falls back per field", outputs: { "DP-1": {} }, name: "DP-1", expected: { path: "", mode: "fill", fillColor: PickerLogic.DEFAULT_COLOR } },
            { tag: "a matched record missing only path falls back for that field alone", outputs: { "DP-1": { mode: "tile", fill_color: "#123456" } }, name: "DP-1", expected: { path: "", mode: "tile", fillColor: "#123456" } }
        ];
    }

    function test_effectiveOutput(row) {
        const effective = PickerLogic.effectiveOutput(row.outputs, row.name);

        compare(effective.path, row.expected.path);
        compare(effective.mode, row.expected.mode);
        compare(effective.fillColor, row.expected.fillColor);
    }

    // effectiveOutput() alone cannot tell "recorded exactly the fallback
    // values" from "never recorded at all" — hasOutputRecord() is what
    // cycleOutput() actually gates on before overwriting the user's live
    // mode/colour cycling.
    function test_hasOutputRecord_data() {
        return [
            { tag: "no state file yet", outputs: null, name: "DP-1", expected: false },
            { tag: "an empty outputs map", outputs: {}, name: "DP-1", expected: false },
            { tag: "a differently named entry only", outputs: { "DP-2": { path: "/a.png", mode: "fill", fill_color: "#d2a1a1" } }, name: "DP-1", expected: false },
            { tag: "a matching entry", outputs: { "DP-1": { path: "/a.png", mode: "fill", fill_color: "#d2a1a1" } }, name: "DP-1", expected: true },
            { tag: "a matching entry with every field omitted still counts as recorded", outputs: { "DP-1": {} }, name: "DP-1", expected: true }
        ];
    }

    function test_hasOutputRecord(row) {
        compare(PickerLogic.hasOutputRecord(row.outputs, row.name), row.expected);
    }

    function test_restoreEntries_only_replays_outputs_with_a_recorded_path() {
        const outputs = {
            "DP-1": { path: "/a.png", mode: "fill", fill_color: "#d2a1a1" },
            "DP-2": { mode: "fill", fill_color: "#d2a1a1" }
        };

        const entries = PickerLogic.restoreEntries(outputs, ["DP-1", "DP-2"]);

        compare(entries.length, 1);
        compare(entries[0].name, "DP-1");
    }

    function test_restoreEntries_is_empty_when_nothing_was_ever_recorded() {
        const entries = PickerLogic.restoreEntries(null, ["DP-1", "DP-2"]);

        compare(entries.length, 0);
    }

    function test_restoreEntries_follows_outputNames_order_for_tinting_from_the_first() {
        const outputs = {
            "DP-1": { path: "/a.png", mode: "fill", fill_color: "#d2a1a1" },
            "DP-2": { path: "/b.png", mode: "fill", fill_color: "#d2a1a1" }
        };

        const entries = PickerLogic.restoreEntries(outputs, ["DP-2", "DP-1"]);

        compare(entries[0].name, "DP-2");
        compare(entries[1].name, "DP-1");
    }

    // Reachability test, tst_tint_wiring.qml's own readSource-plus-indexOf
    // idiom: qmltestrunner cannot instantiate Picker.qml at all (it reaches
    // Quickshell.Io's Process/FileView, whose plugin is linked into the
    // quickshell binary rather than loadable standalone), so the adapter
    // wiring that outputRecords depends on has no live test — this reads
    // the shipped source instead. Motivating bug: outputRecords read
    // `.adapter.root`, which does not exist anywhere on Quickshell 0.3.0's
    // JsonAdapter (confirmed against quickshell-io.qmltypes), so it was
    // silently undefined forever and every write merged onto nothing.
    // Nothing caught that for as long as this assertion did not exist.
    function readSource(relPath) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl(relPath), false);
        xhr.send();
        compare(xhr.status, 200, relPath + " must be readable (needs QML_XHR_ALLOW_FILE_READ=1)");
        return xhr.responseText;
    }

    function test_picker_never_reads_the_nonexistent_adapter_root() {
        const picker = readSource("../../nix/home/quickshell/qml/wallpaper/Picker.qml");
        verify(picker.indexOf(".adapter.root") === -1, "JsonAdapter has no `root` property on this Quickshell build — reading .adapter.root is silently always undefined");
    }

    function test_picker_declares_a_property_for_the_adapter_to_populate() {
        const picker = readSource("../../nix/home/quickshell/qml/wallpaper/Picker.qml");
        verify(picker.indexOf("property var outputs") !== -1, "JsonAdapter only populates a property declared on the adapter instance itself — a bare JsonAdapter {} has nothing for the parsed JSON to land on");
    }

    // Slices out recordOutputState()'s own body, so a `outputStateKnown`
    // mention anywhere ELSE in the file (this comment included, if it
    // said the word directly) cannot satisfy this test.
    function recordOutputStateBody() {
        const picker = readSource("../../nix/home/quickshell/qml/wallpaper/Picker.qml");
        const start = picker.indexOf("function recordOutputState(");
        verify(start !== -1, "Picker.qml must define recordOutputState(entry)");
        const end = picker.indexOf("\n    }", start);
        verify(end !== -1, "recordOutputState(entry)'s closing brace must be found");
        return picker.slice(start, end);
    }

    // Motivating bug: recordOutputState() gated on outputStateFile.loaded,
    // which a missing outputs.json never sets — Quickshell resolves that
    // case through loadFailed instead, so a fresh install's first apply
    // queued forever and the file it was waiting on never got created to
    // unstick it. Pins the fix at the one call site that actually matters
    // — a revert back to `.loaded` here reintroduces the deadlock even if
    // onLoadFailed elsewhere in the file is left wired up.
    function test_recordOutputState_gates_on_outputStateKnown_not_loaded() {
        const body = recordOutputStateBody();

        verify(body.indexOf("outputStateKnown") !== -1, "recordOutputState() must gate on outputStateKnown, not a re-added .loaded check");
        verify(body.indexOf(".loaded") === -1, "recordOutputState() must not go back to gating on outputStateFile.loaded — that deadlocks on a fresh install, since a missing file resolves through loadFailed, never loaded");
    }

    // A missing outputs.json resolves through loadFailed, never loaded —
    // confirmed live, not assumed (see task-2-report.md). Without this
    // handler wired up, recordOutputState()'s queue above is internally
    // consistent but nothing ever calls flushPendingOutputRecords() on a
    // fresh install, so the deadlock returns even with the gate itself
    // fixed.
    function test_picker_flushes_on_both_loaded_and_loadFailed() {
        const picker = readSource("../../nix/home/quickshell/qml/wallpaper/Picker.qml");
        verify(picker.indexOf("onLoadFailed:") !== -1, "a missing outputs.json resolves through loadFailed, never loaded — the flush must be wired to both");
    }

    // Slices out flushPendingOutputRecords()'s own body, the same way
    // recordOutputStateBody() does above.
    function flushPendingOutputRecordsBody() {
        const picker = readSource("../../nix/home/quickshell/qml/wallpaper/Picker.qml");
        const start = picker.indexOf("function flushPendingOutputRecords(");
        verify(start !== -1, "Picker.qml must define flushPendingOutputRecords()");
        const end = picker.indexOf("\n    }", start);
        verify(end !== -1, "flushPendingOutputRecords()'s closing brace must be found");
        return picker.slice(start, end);
    }

    // drainPending() itself is tested above, but nothing pinned that its
    // result actually gets written back here: deleting just this
    // assignment leaves outputStateKnown set and the first write still
    // happening, but pendingOutputRecords never actually empties, so the
    // very next onLoaded/onLoadFailed (an external edit, or watchChanges
    // catching this file's own write) finds the same records still
    // queued and writes them a second time.
    function test_flushPendingOutputRecords_writes_the_drained_queue_back() {
        const body = flushPendingOutputRecordsBody();
        verify(body.indexOf("root.pendingOutputRecords = decision.queue") !== -1, "flushPendingOutputRecords() must write drainPending()'s emptied queue back to pendingOutputRecords, or a queued record gets written a second time on the next reload");
    }
}
