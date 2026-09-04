// Per-tab navigation history, driven with plain objects and no window.
//
// Every bug in this state machine is invisible until an arrow sends you
// somewhere you never were, which is why the whole cursor dance is pinned
// here rather than left to the two callers in Files.qml.
import QtQuick
import QtTest
import "../../nix/home/desktop/quickshell/qml/files/history.js" as History

TestCase {
    name: "FilesHistory"

    function test_a_fresh_history_sits_on_its_only_entry() {
        const h = History.initial("/home/matus");

        compare(History.currentOf(h), "/home/matus");
        verify(!History.canBack(h));
        verify(!History.canForward(h));
    }

    function test_pushing_advances_and_unlocks_back() {
        const h = History.pushed(History.initial("/a"), "/b");

        compare(History.currentOf(h), "/b");
        verify(History.canBack(h));
        verify(!History.canForward(h));
    }

    function test_back_returns_and_unlocks_forward() {
        const h = History.back(History.pushed(History.initial("/a"), "/b"));

        compare(History.currentOf(h), "/a");
        verify(!History.canBack(h));
        verify(History.canForward(h));
    }

    function test_forward_returns_to_where_back_came_from() {
        const there = History.pushed(History.initial("/a"), "/b");

        compare(History.currentOf(History.forward(History.back(there))), "/b");
    }

    // The browser rule: going somewhere new from the middle discards what
    // was ahead, so Forward means "the way I came back from" and never
    // "some path I once visited".
    function test_navigating_from_the_middle_discards_the_forward_entries() {
        let h = History.pushed(History.initial("/a"), "/b");
        h = History.pushed(h, "/c");
        h = History.back(h);
        verify(History.canForward(h));

        h = History.pushed(h, "/d");

        compare(History.currentOf(h), "/d");
        verify(!History.canForward(h));
        compare(History.back(h).entries.length, 3);
    }

    // Without this, double-clicking the same folder twice would take two
    // Backs to leave, and so would a post-operation re-list.
    function test_navigating_to_where_you_already_are_is_not_an_entry() {
        const h = History.pushed(History.initial("/a"), "/a");

        verify(!History.canBack(h));
        compare(h.entries.length, 1);
    }

    function test_back_at_the_start_and_forward_at_the_end_do_nothing() {
        const start = History.initial("/a");

        compare(History.currentOf(History.back(start)), "/a");
        compare(History.currentOf(History.forward(start)), "/a");
    }

    // QML only re-evaluates a `var` binding when the property is
    // reassigned, so every one of these has to hand back a new object
    // rather than moving a cursor in place.
    function test_nothing_mutates_its_argument() {
        const h = History.initial("/a");
        const moved = History.pushed(h, "/b");

        compare(h.entries.length, 1);
        compare(h.index, 0);
        compare(moved.index, 1);
    }
}
