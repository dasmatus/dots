// Arrange.qml's coordinate math and overrides merge, pure and tested
// without a live PanelWindow, MouseArea drag or Hyprland singleton — see
// arrange.js's own header for why the logic lives there rather than in the
// component.
import QtQuick
import QtTest
import "../../nix/home/quickshell/qml/monitors/arrange.js" as ArrangeLogic

TestCase {
    name: "Arrange"

    function test_fitTransform_centers_and_scales_to_fit() {
        // Two 1920x1080 monitors side by side: a 3840x1080 bounding box into
        // a 720x420 canvas is width-bound (720/3840 < 420/1080), so the
        // scale is that ratio times the 0.9 margin.
        const monitors = [
            { x: 0, y: 0, width: 1920, height: 1080 },
            { x: 1920, y: 0, width: 1920, height: 1080 }
        ];
        const transform = ArrangeLogic.fitTransform(monitors, 720, 420);

        compare(transform.originX, 0);
        compare(transform.originY, 0);
        const expectedScale = Math.min(720 / 3840, 420 / 1080) * 0.9;
        fuzzyCompare(transform.scale, expectedScale, 0.0001);
    }

    function test_fitTransform_is_empty_safe() {
        const transform = ArrangeLogic.fitTransform([], 720, 420);

        compare(transform.originX, 0);
        compare(transform.originY, 0);
        compare(transform.scale, 1);
    }

    // toScreen/toWorldPosition must round-trip: dragging a rectangle to
    // some canvas position and reading it back must return the same real
    // pixel position the monitor was originally placed at, when nothing
    // moved.
    function test_toScreen_and_toWorldPosition_round_trip() {
        const monitors = [
            { x: 0, y: 0, width: 1920, height: 1080 },
            { x: 1920, y: 0, width: 2560, height: 1200 }
        ];
        const transform = ArrangeLogic.fitTransform(monitors, 720, 420);

        for (const m of monitors) {
            const screen = ArrangeLogic.toScreen(m, transform);
            const world = ArrangeLogic.toWorldPosition(screen.x, screen.y, transform);
            compare(world, `${m.x}x${m.y}`);
        }
    }

    function test_closestWithin_data() {
        return [
            { tag: "snaps when within threshold", value: 100, targets: [104], threshold: 10, expected: 104 },
            { tag: "leaves the value when nothing is close enough", value: 100, targets: [200], threshold: 10, expected: 100 },
            { tag: "picks the nearest of several candidates", value: 100, targets: [108, 103], threshold: 10, expected: 103 },
            { tag: "no targets leaves the value alone", value: 100, targets: [], threshold: 10, expected: 100 }
        ];
    }

    function test_closestWithin(row) {
        compare(ArrangeLogic.closestWithin(row.value, row.targets, row.threshold), row.expected);
    }

    // The scenario the feature exists for: two monitors dragged near enough
    // to sit flush snap exactly flush, not a pixel or two off.
    function test_snappedPosition_snaps_a_dragged_edge_to_its_neighbour() {
        const other = { x: 0, y: 0, width: 400, height: 300 };
        const dragged = { x: 405, y: 40, width: 300, height: 200 };

        const snapped = ArrangeLogic.snappedPosition(dragged, [other, dragged], 14);

        compare(snapped.x, 400);
        compare(snapped.y, 40);
    }

    function test_snappedPosition_ignores_itself_in_the_neighbour_list() {
        const solo = { x: 50, y: 60, width: 300, height: 200 };

        const snapped = ArrangeLogic.snappedPosition(solo, [solo], 14);

        compare(snapped.x, 50);
        compare(snapped.y, 60);
    }

    function test_mergedOverrides_data() {
        return [
            {
                tag: "a fresh overrides.json gets one entry per dragged monitor",
                existingRoot: null,
                items: [{ name: "DP-1", position: "0x0" }],
                expected: { entries: [{ name: "DP-1", position: "0x0" }] }
            },
            {
                tag: "a name-matched entry keeps its other fields and only position changes",
                existingRoot: { entries: [{ name: "DP-1", resolution: "1920x1080@240", vrr: "left" }] },
                items: [{ name: "DP-1", position: "1920x0" }],
                expected: { entries: [{ name: "DP-1", resolution: "1920x1080@240", vrr: "left", position: "1920x0" }] }
            },
            {
                tag: "an entry for a monitor absent from the current drag is left alone",
                existingRoot: { entries: [{ name: "DP-9", position: "9999x0" }] },
                items: [{ name: "DP-1", position: "0x0" }],
                expected: { entries: [{ name: "DP-9", position: "9999x0" }, { name: "DP-1", position: "0x0" }] }
            }
        ];
    }

    function test_mergedOverrides(row) {
        const merged = ArrangeLogic.mergedOverrides(row.existingRoot, row.items);
        compare(merged.entries.length, row.expected.entries.length);
        for (let i = 0; i < row.expected.entries.length; i++) {
            const want = row.expected.entries[i];
            for (const key in want)
                compare(merged.entries[i][key], want[key]);
        }
    }
}
