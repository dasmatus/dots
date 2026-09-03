// Reachability test, tst_tint_wiring.qml's own pattern: proves Launcher.qml
// actually calls into pills.js and wires the pill bar's interaction, not
// just that pillsFor/filterByPill are correct in isolation (tst_pills.qml
// already covers that).
//
// Motivating bug, this file's own round 1: pillsFor and filterByPill were
// unit-tested and correct while Launcher.qml's `pills` property read from
// the wrong (post-sort) list, and while nothing anywhere reset
// `selectedPill` when the query changed — every unit test on pills.js
// itself stayed green through both, because neither looks at the caller.
//
// qmltestrunner cannot instantiate Launcher.qml: it reaches PanelWindow,
// WlrLayershell and IpcHandler, all Quickshell types tests/README.md rules
// out — so this reads the shipped source as text instead, the same XHR
// idiom tst_monitor_parity.qml and tst_tint_wiring.qml use.
import QtQuick
import QtTest
import "sourcescan.js" as Scan

TestCase {
    name: "PillWiring"

    // Comment-stripped, for the reason sourcescan.js's own header records:
    // an assertion looking for a binding will happily match a comment that
    // merely mentions it by name. The pill delegate is now several lines of
    // prose explaining the drill, so this file is squarely in range of that
    // failure rather than theoretically exposed to it.
    function readSource(relPath) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl(relPath), false);
        xhr.send();
        compare(xhr.status, 200, relPath + " must be readable (needs QML_XHR_ALLOW_FILE_READ=1)");
        return Scan.stripComments(xhr.responseText);
    }

    function launcherSource() {
        return readSource("../../nix/home/quickshell/qml/launcher/Launcher.qml");
    }

    function test_pills_are_computed_from_the_pure_function() {
        verify(launcherSource().indexOf("Pills.pillsFor(") !== -1, "the pill bar must be built from pills.js's pillsFor, not hand-rolled");
    }

    // Round 1's actual bug: pills read from `unfilteredResults`, the
    // post-sort/post-slice list, so the bar's own order churned as scores
    // changed between keystrokes — exactly what pills.js's own comment says
    // computing from registry order prevents. Pinning the property's exact
    // source, not just that pillsFor is called somewhere, is what stops a
    // future edit from quietly pointing it at the wrong list again.
    //
    // Round 2's bug: pointing pillsFor at ambientRows alone fixed the order
    // but broke agreement — ambientRows is untruncated, so a provider pushed
    // past unfilteredResults' 50-row cap could keep a nonzero pill for rows
    // clicking it would never show. pillsFor now takes ambientRows for order
    // and unfilteredResults for counts; pinning both arguments, not just the
    // first, is what stops a future edit from quietly dropping the second.
    function test_pills_read_order_from_ambient_and_counts_from_unfiltered() {
        verify(launcherSource().indexOf("Pills.pillsFor(root.ambientRows, root.unfilteredResults)") !== -1, "pills must take order from ambientRows (registry order) and counts from unfilteredResults (the list `results` actually filters)");
    }

    function test_results_are_filtered_through_the_pure_function() {
        verify(launcherSource().indexOf("Pills.filterByPill(") !== -1, "the shown results must be filtered through pills.js's filterByPill");
    }

    function test_pill_delegate_is_interactive() {
        verify(launcherSource().indexOf("interactive: true") !== -1, "the Pill delegate must set interactive: true or the pointer cannot drive it");
    }

    // The handler stopped being a one-line assignment when the drill pill
    // arrived: clicking a pill now either leaves an app's action list or
    // toggles the provider filter, so it is a block with both paths in it.
    // Both are still pinned, because a click that reaches neither is a pill
    // that does nothing — the failure this test exists to catch.
    function test_pill_click_assigns_the_selection() {
        const delegate = Scan.blockAfter(launcherSource(), "delegate: Pill {");
        verify(delegate !== "", "the pill bar must build its delegate from the shared Pill");

        verify(delegate.indexOf("root.selectedPill = ") !== -1, "clicking a pill must assign root.selectedPill");
        verify(delegate.indexOf("root.drillOut()") !== -1, "clicking the drill pill must leave the drill, since it is the only visible way back out with the pointer");
    }

    function test_tab_and_backtab_reach_cyclePill() {
        const src = launcherSource();
        verify(src.indexOf("Keys.onTabPressed: root.cyclePill(1)") !== -1, "Tab must reach cyclePill — the keyboard half of pointer-driven pills");
        verify(src.indexOf("Keys.onBacktabPressed: root.cyclePill(-1)") !== -1, "Shift+Tab must reach cyclePill the other direction");
    }

    // Slices out onTextChanged's own body, so a `selectedPill = ""` sitting
    // anywhere ELSE in the file (show(), a comment) cannot satisfy this —
    // the release has to happen on the one handler every keystroke reaches.
    function test_every_keystroke_releases_the_engaged_pill() {
        const src = launcherSource();
        const start = src.indexOf("onTextChanged: {");
        verify(start !== -1, "TextInput must define onTextChanged");
        const end = src.indexOf("Keys.onDownPressed", start);
        verify(end !== -1, "onTextChanged's block must be followed by the Keys handlers");
        const body = src.slice(start, end);
        verify(body.indexOf("root.selectedPill = \"\"") !== -1, "editing the query must release the engaged pill (rust/beamenu/tests/pills.rs: editing_the_query_releases_the_engaged_provider)");
    }
}
