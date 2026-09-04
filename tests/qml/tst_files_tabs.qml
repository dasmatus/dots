// Tab arithmetic for Files.qml, driven with plain objects and no window.
//
// Every function here returns a new array on purpose: QML only re-evaluates
// a `var` binding when the property is reassigned, so a push() into the
// existing array would update the model and draw nothing. The
// does-not-mutate tests are what keep that property from being optimised
// away by someone who has not hit the bug.
import QtQuick
import QtTest
import "../../nix/home/desktop/quickshell/qml/files/tabs.js" as Tabs

TestCase {
    name: "FilesTabs"

    function test_a_new_tab_holds_the_path_it_was_opened_on() {
        compare(Tabs.newTab("/home/matus").path, "/home/matus");
    }

    function test_opening_appends_without_mutating() {
        const tabs = [Tabs.newTab("/a")];
        const next = Tabs.opened(tabs, "/b");

        compare(next.length, 2);
        compare(next[1].path, "/b");
        compare(tabs.length, 1);
    }

    function test_closing_removes_the_named_tab_without_mutating() {
        const tabs = [Tabs.newTab("/a"), Tabs.newTab("/b"), Tabs.newTab("/c")];
        const next = Tabs.closed(tabs, 1);

        compare(next.length, 2);
        compare(next[0].path, "/a");
        compare(next[1].path, "/c");
        compare(tabs.length, 3);
    }

    // A file manager with no tab has nothing to draw and no way back, so
    // the floor is one rather than an empty window to reopen.
    function test_the_last_tab_cannot_be_closed() {
        compare(Tabs.closed([Tabs.newTab("/a")], 0).length, 1);
    }

    // Closing the tab you are on, or one to its left, walks the selection
    // left; closing one to its right leaves it where it is.
    function test_the_selection_walks_left_when_the_active_tab_closes() {
        const tabs = [Tabs.newTab("/a"), Tabs.newTab("/b"), Tabs.newTab("/c")];

        compare(Tabs.indexAfterClose(tabs, 2, 2), 1);
        compare(Tabs.indexAfterClose(tabs, 1, 2), 1);
        compare(Tabs.indexAfterClose(tabs, 2, 0), 0);
    }

    function test_closing_the_first_tab_keeps_the_selection_at_zero() {
        compare(Tabs.indexAfterClose([Tabs.newTab("/a"), Tabs.newTab("/b")], 0, 0), 0);
    }

    function test_clampindex_stays_inside_the_array() {
        compare(Tabs.clampIndex(5, 3), 2);
        compare(Tabs.clampIndex(-1, 3), 0);
        compare(Tabs.clampIndex(0, 0), 0);
    }

    // gt/gT's arithmetic: one step, wrapping at either end.
    function test_cycleindex_wraps_at_both_ends() {
        compare(Tabs.cycleIndex(2, 3, 1), 0, "forward past the last tab wraps to the first");
        compare(Tabs.cycleIndex(0, 3, -1), 2, "backward past the first tab wraps to the last");
        compare(Tabs.cycleIndex(0, 1, 1), 0, "a single tab has nowhere to go, forward");
        compare(Tabs.cycleIndex(0, 1, -1), 0, "a single tab has nowhere to go, backward");
        compare(Tabs.cycleIndex(0, 0, 1), 0, "an empty list stays at zero rather than dividing by it");
    }

    // One path component is what a tab strip has room for, and the full path
    // already sits in the pane header below it.
    function test_the_label_is_the_basename() {
        compare(Tabs.labelFor({ path: "/home/matus/Dokumente" }), "Dokumente");
    }

    function test_the_label_of_root_is_the_slash_itself() {
        compare(Tabs.labelFor({ path: "/" }), "/");
    }

    function test_a_trailing_slash_does_not_empty_the_label() {
        compare(Tabs.labelFor({ path: "/home/matus/Musik/" }), "Musik");
    }
}
