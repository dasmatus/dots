// picker.js's pure cycling and grid-cursor math, tested without a live
// Picker.qml — that component reaches Quickshell.Io's Process, which
// qmltestrunner cannot instantiate (see tst_tint_wiring.qml's header for
// the same constraint on the tint targets).
import QtQuick
import QtTest
import "../../nix/home/quickshell/qml/wallpaper/picker.js" as PickerLogic

TestCase {
    name: "Picker"

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
}
