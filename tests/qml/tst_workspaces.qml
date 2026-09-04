// Workspace icon-cap arithmetic.
//
// The regression this guards against: a workspace with far more windows
// open than the bar has room for must still report a bounded icon count and
// a correct, non-negative overflow, rather than growing the row until it
// pushes the clock off the bar.
import QtQuick
import QtTest
import "../../nix/home/desktop/quickshell/qml/bar/workspaces.js" as Workspaces

TestCase {
    name: "Workspaces"

    function test_shownCount_is_bounded_by_the_cap_data() {
        return [
            { tag: "empty", total: 0, cap: 4, expected: 0 },
            { tag: "under the cap", total: 2, cap: 4, expected: 2 },
            { tag: "exactly the cap", total: 4, cap: 4, expected: 4 },
            { tag: "over the cap", total: 15, cap: 4, expected: 4 }
        ];
    }

    function test_shownCount_is_bounded_by_the_cap(row) {
        compare(Workspaces.shownCount(row.total, row.cap), row.expected);
    }

    function test_overflowCount_is_never_negative_data() {
        return [
            { tag: "empty", total: 0, cap: 4, expected: 0 },
            { tag: "under the cap", total: 2, cap: 4, expected: 0 },
            { tag: "exactly the cap", total: 4, cap: 4, expected: 0 },
            { tag: "one over", total: 5, cap: 4, expected: 1 },
            { tag: "fifteen windows", total: 15, cap: 4, expected: 11 }
        ];
    }

    function test_overflowCount_is_never_negative(row) {
        compare(Workspaces.overflowCount(row.total, row.cap), row.expected);
    }

    // shownCount + overflowCount must always account for every window: a
    // workspace with `total` toplevels never gains or loses one on the way
    // to the bar.
    function test_shown_plus_overflow_accounts_for_every_window_data() {
        return [
            { tag: "empty", total: 0, cap: 4 },
            { tag: "under the cap", total: 3, cap: 4 },
            { tag: "at the cap", total: 4, cap: 4 },
            { tag: "far over", total: 15, cap: 4 }
        ];
    }

    function test_shown_plus_overflow_accounts_for_every_window(row) {
        const shown = Workspaces.shownCount(row.total, row.cap);
        const overflow = Workspaces.overflowCount(row.total, row.cap);
        compare(shown + overflow, row.total);
    }
}
