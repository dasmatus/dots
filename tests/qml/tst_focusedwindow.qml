// FocusedWindow pill's title-elision arithmetic.
//
// The regression this guards against: FocusedWindow.qml used to be a bare
// RowLayout with Layout.maximumWidth: Theme.barTitleMaxWidth capping the
// title directly. Once it became a Pill, that same 480px budget has to pay
// for the Pill's own horizontalPadding on both sides and, when the icon is
// showing, the icon's width and Pill.qml's internal Row gap too — a plain
// `width: Theme.barTitleMaxWidth` left on the Text would let a long title
// push the capsule 40-odd pixels wider than the bar actually budgets for.
//
// Numbers here are the bar's own real tokens (Theme.barTitleMaxWidth: 480,
// Theme.barPillPadding: 14, Theme.barIconSize: 20), not invented ones — see
// nix/data/palette.json's `bar` block.
import QtQuick
import QtTest
import "../../nix/home/desktop/quickshell/qml/bar/focusedwindow.js" as FocusedWindow

TestCase {
    name: "FocusedWindow"

    // Icon absent and no toplevel at all reach the same input: entry is
    // null (or entry.icon is falsy) either way, so FocusedWindow.qml's own
    // `hasIcon` is false for both — a window with an unresolved desktop
    // entry and no focused window at all collapse to one row rather than
    // two identical ones, the same way FocusedWindow.qml's `iconSource`
    // binding does not distinguish them either.
    function test_availableTitleWidth_matches_the_bars_real_tokens_data() {
        return [
            { tag: "no icon (no toplevel, or a window with no resolvable desktop icon)", cap: 480, padding: 14, iconSize: 20, hasIcon: false, expected: 452 },
            { tag: "icon present", cap: 480, padding: 14, iconSize: 20, hasIcon: true, expected: 426 }
        ];
    }

    function test_availableTitleWidth_matches_the_bars_real_tokens(row) {
        compare(FocusedWindow.availableTitleWidth(row.cap, row.padding, row.iconSize, row.hasIcon), row.expected);
    }

    // A title shorter than the cap is the ordinary case pinned above: both
    // rows leave comfortable, unclamped headroom (426 and 452 are both well
    // short of going negative), which is what lets a short title like
    // "kitty" render at its own natural width instead of stretching the
    // capsule out to the full budget.
    function test_availableTitleWidth_leaves_real_headroom_for_a_short_title() {
        const width = FocusedWindow.availableTitleWidth(480, 14, 20, true);
        verify(width > 0, "the bar's real tokens must never clamp to zero");
        compare(width, 426);
    }

    // A title far longer than the cap is only interesting once the cap
    // itself cannot even cover the fixed costs around it — the case a naive
    // `cap - padding * 2 - iconAllowance` would hand back as a negative
    // number, which Text has no defined behaviour for. However long the
    // real title is, the result must still be a usable, non-negative width.
    function test_availableTitleWidth_clamps_at_zero_when_reductions_exceed_the_cap_data() {
        return [
            { tag: "reductions exceed the cap", cap: 20, padding: 14, iconSize: 20, hasIcon: true },
            { tag: "reductions exactly consume the cap", cap: 54, padding: 14, iconSize: 20, hasIcon: true }
        ];
    }

    function test_availableTitleWidth_clamps_at_zero_when_reductions_exceed_the_cap(row) {
        compare(FocusedWindow.availableTitleWidth(row.cap, row.padding, row.iconSize, row.hasIcon), 0);
    }
}
