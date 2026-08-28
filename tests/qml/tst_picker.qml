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

    function test_mergeOutputState_a_fresh_file_gets_one_entry_per_record() {
        const merged = PickerLogic.mergeOutputState(null, [{ name: "DP-1", path: "/a.png", mode: "fill", fillColor: "#d2a1a1" }]);

        compare(merged.entries.length, 1);
        compare(merged.entries[0].name, "DP-1");
        compare(merged.entries[0].path, "/a.png");
        compare(merged.entries[0].mode, "fill");
        compare(merged.entries[0].fillColor, "#d2a1a1");
    }

    function test_mergeOutputState_a_name_matched_entry_is_fully_replaced() {
        const existingRoot = { entries: [{ name: "DP-1", path: "/old.png", mode: "tile", fillColor: "#000000" }] };
        const merged = PickerLogic.mergeOutputState(existingRoot, [{ name: "DP-1", path: "/new.png", mode: "fit", fillColor: "#ffffff" }]);

        compare(merged.entries.length, 1);
        compare(merged.entries[0].path, "/new.png");
        compare(merged.entries[0].mode, "fit");
        compare(merged.entries[0].fillColor, "#ffffff");
    }

    function test_mergeOutputState_an_entry_absent_from_records_is_left_alone() {
        const existingRoot = { entries: [{ name: "DP-9", path: "/untouched.png", mode: "fill", fillColor: "#d2a1a1" }] };
        const merged = PickerLogic.mergeOutputState(existingRoot, [{ name: "DP-1", path: "/a.png", mode: "fill", fillColor: "#d2a1a1" }]);

        compare(merged.entries.length, 2);
        const dp9 = merged.entries.find(e => e.name === "DP-9");
        compare(dp9.path, "/untouched.png");
    }

    function test_mergeOutputState_a_wildcard_apply_records_every_name_at_once() {
        const merged = PickerLogic.mergeOutputState(null, [
            { name: "DP-1", path: "/a.png", mode: "fill", fillColor: "#d2a1a1" },
            { name: "DP-2", path: "/a.png", mode: "fill", fillColor: "#d2a1a1" }
        ]);

        compare(merged.entries.length, 2);
    }

    function test_effectiveOutput_data() {
        return [
            { tag: "no state file yet falls back", outputState: null, name: "DP-1", expected: { path: "", mode: "fill", fillColor: PickerLogic.DEFAULT_COLOR } },
            { tag: "an empty entries list falls back", outputState: { entries: [] }, name: "DP-1", expected: { path: "", mode: "fill", fillColor: PickerLogic.DEFAULT_COLOR } },
            { tag: "a recorded output returns its own record", outputState: { entries: [{ name: "DP-1", path: "/a.png", mode: "tile", fillColor: "#123456" }] }, name: "DP-1", expected: { path: "/a.png", mode: "tile", fillColor: "#123456" } },
            { tag: "a differently named entry does not match", outputState: { entries: [{ name: "DP-2", path: "/a.png", mode: "tile", fillColor: "#123456" }] }, name: "DP-1", expected: { path: "", mode: "fill", fillColor: PickerLogic.DEFAULT_COLOR } },
            { tag: "an empty field on a matched record falls back per field", outputState: { entries: [{ name: "DP-1", path: "/a.png", mode: "", fillColor: "" }] }, name: "DP-1", expected: { path: "/a.png", mode: "fill", fillColor: PickerLogic.DEFAULT_COLOR } }
        ];
    }

    function test_effectiveOutput(row) {
        const effective = PickerLogic.effectiveOutput(row.outputState, row.name);

        compare(effective.path, row.expected.path);
        compare(effective.mode, row.expected.mode);
        compare(effective.fillColor, row.expected.fillColor);
    }

    function test_restoreEntries_only_replays_outputs_with_a_recorded_path() {
        const outputState = {
            entries: [
                { name: "DP-1", path: "/a.png", mode: "fill", fillColor: "#d2a1a1" },
                { name: "DP-2", path: "", mode: "fill", fillColor: "#d2a1a1" }
            ]
        };

        const entries = PickerLogic.restoreEntries(outputState, ["DP-1", "DP-2"]);

        compare(entries.length, 1);
        compare(entries[0].name, "DP-1");
    }

    function test_restoreEntries_is_empty_when_nothing_was_ever_recorded() {
        const entries = PickerLogic.restoreEntries(null, ["DP-1", "DP-2"]);

        compare(entries.length, 0);
    }

    function test_restoreEntries_follows_outputNames_order_for_tinting_from_the_first() {
        const outputState = {
            entries: [
                { name: "DP-1", path: "/a.png", mode: "fill", fillColor: "#d2a1a1" },
                { name: "DP-2", path: "/b.png", mode: "fill", fillColor: "#d2a1a1" }
            ]
        };

        const entries = PickerLogic.restoreEntries(outputState, ["DP-2", "DP-1"]);

        compare(entries[0].name, "DP-2");
        compare(entries[1].name, "DP-1");
    }
}
