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
        return readSource("../../nix/home/desktop/quickshell/qml/launcher/Launcher.qml");
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

    // The bar used to be a Flow that wrapped onto up to Theme.launcherPillRows
    // rows, costing the result list that much height whenever an empty query
    // matched enough apps with actions. It is one scrolling row now, and
    // every one of those four checks is a way the wrap could quietly come
    // back: a live `Flow {` is the wrapping positioner itself, a live
    // `Theme.launcherPillRows` is the multi-row height cap that positioner
    // needed, a missing `flickableDirection: Flickable.HorizontalFlick` lets
    // a vertical drag rubber-band content that no longer has anything above
    // or below it, and a `contentWidth` still bound to the viewport's own
    // `width` (rather than to `pillRow.implicitWidth`) is the exact binding
    // that used to tell a Flow where to wrap.
    function test_the_pill_bar_is_one_scrolling_row() {
        const src = launcherSource();
        verify(src.indexOf("Flow {") === -1, "the pill bar must not be a Flow — wrapping is the shape this change removed");
        verify(src.indexOf("Theme.launcherPillRows") === -1, "the multi-row height cap must not come back — a single row is always exactly one Pill tall");
        verify(src.indexOf("flickableDirection: Flickable.HorizontalFlick") !== -1, "the bar must be pinned to horizontal flicking, or a vertical drag rubber-bands content that has nothing above or below it");
        verify(src.indexOf("contentWidth: pillRow.implicitWidth") !== -1, "the viewport's contentWidth must follow the content-sized row, not a fixed width — a width-bound contentWidth is the wrap quietly re-emerging");
    }

    // Tab/Shift+Tab move root.selectedPill, and a selection the viewport
    // never scrolls to is a keystroke with no visible effect. Both halves are
    // pinned: the trigger (the provider delegate calling ensureVisible when
    // it becomes active) and the mechanism (ensureVisible actually moving
    // contentX) — a caller that never assigns contentX would satisfy a bare
    // "ensureVisible(" search while doing nothing.
    function test_tab_selection_scrolls_into_view() {
        const src = launcherSource();

        const delegate = Scan.blockAfter(src, "delegate: Pill {");
        verify(delegate !== "", "the pill bar must build its delegate from the shared Pill");
        const activeChanged = Scan.blockAfter(delegate, "onActiveChanged: {");
        verify(activeChanged !== "", "the provider pill delegate must react to its own active state changing");
        verify(activeChanged.indexOf("pillScroll.ensureVisible(") !== -1, "becoming the active pill must scroll it into view");

        const ensureVisible = Scan.blockAfter(src, "function ensureVisible(item: Item): void {");
        verify(ensureVisible !== "", "pillScroll must define ensureVisible");
        verify(ensureVisible.indexOf("pillScroll.scrollTo(") !== -1, "ensureVisible must actually move the bar, or scrolling a pill into view does nothing");

        // Every mover goes through scrollTo, and scrollTo is the only place
        // the scrollable range is spelled out. Three callers open-coding the
        // same Math.max/Math.min pair was three places for a later change to
        // that range to miss, which is the state these two pin shut.
        const scrollTo = Scan.blockAfter(src, "function scrollTo(x: real): void {");
        verify(scrollTo !== "", "pillScroll must define scrollTo");
        verify(scrollTo.indexOf("pillScroll.contentX = ") !== -1, "scrollTo must assign contentX — it is the one thing that moves this bar");
        verify(scrollTo.indexOf("pillScroll.contentWidth - pillScroll.width") !== -1, "scrollTo must clamp to the scrollable range, or a caller can park the bar past its own content");
    }

    // WheelHandler is the only thing that can map a vertical wheel onto this
    // horizontally-scrolling bar — Flickable never cross-maps an axis on its
    // own. Declared between pillScroll and pillRow (the whole viewport, not
    // just the row) so a pointer over any part of the bar, pills included,
    // reaches it; a MouseArea in that same span would be the click-swallowing
    // shape this design rejected in favour of a pointer handler.
    function test_vertical_wheel_drives_the_bar() {
        const src = launcherSource();
        const barAt = src.indexOf("id: pillScroll");
        const rowAt = src.indexOf("id: pillRow");
        verify(barAt !== -1 && rowAt !== -1 && rowAt > barAt, "pillScroll must be declared before pillRow");

        const viewport = src.slice(barAt, rowAt);
        verify(viewport.indexOf("WheelHandler {") !== -1, "the viewport must declare a WheelHandler to map vertical wheel input onto horizontal scrolling");
        verify(viewport.indexOf("MouseArea") === -1, "no MouseArea may sit over the bar — it would swallow the pills' own clicks");

        const handler = Scan.blockAfter(viewport, "WheelHandler {");
        verify(handler !== "", "the WheelHandler must be a real block");
        verify(handler.indexOf("target: null") !== -1, "the handler must manipulate nothing automatically — it exists only for its wheel signal");
        verify(handler.indexOf("angleDelta.y") !== -1, "the handler must read the wheel's vertical delta");
        verify(handler.indexOf("pillScroll.scrollTo(") !== -1, "the handler must drive the bar through scrollTo — angleDelta alone scrolls nothing");
    }

    // pillRow is content-sized (a Row, not a width-bound Flow), so a Text
    // width capped against pillRow.width would read a value that depends on
    // that same Text's own width — a binding loop. The cap has to read the
    // viewport's width instead, which the ColumnLayout assigns independently
    // of what the row inside it adds up to.
    function test_the_action_pill_cap_reads_the_viewport() {
        const src = launcherSource();
        verify(src.indexOf("pillScroll.width * Theme.launcherActionPillMaxFactor") !== -1, "the drill capsule's label width must be capped against the viewport (pillScroll), not the content-sized row");
        verify(src.indexOf("pillRow.width * Theme.launcherActionPillMaxFactor") === -1, "capping against pillRow.width is a binding loop once pillRow is content-sized");
    }
}
