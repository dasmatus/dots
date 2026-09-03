// Reachability tests for the launcher's ranking and drill-in, in the idiom
// tst_pill_wiring.qml established: qmltestrunner cannot instantiate
// Launcher.qml or Providers.qml — both reach Quickshell.Io, and Launcher also
// reaches PanelWindow, WlrLayershell and IpcHandler, all of which tests/README.md
// rules out — so these read the shipped source as text.
//
// rank.js and apps.js are unit-tested in isolation by tst_rank.qml and
// tst_apps.qml. That is exactly the coverage that stays green while nothing
// calls them, or while a caller passes the wrong list, which is the gap this
// file closes. Every assertion here is about a CALLER.
//
// Everything is checked against comment-stripped source. The prose in these
// files mentions `root.drill`, `Rank.order` and `recordUse` by name while
// explaining why they are shaped the way they are, and an unstripped scan
// would let a comment stand in for the binding it describes — the failure
// sourcescan.js's own header records having been bitten by once already.
import QtQuick
import QtTest
import "sourcescan.js" as Scan

TestCase {
    name: "LauncherWiring"

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

    function providersSource() {
        return readSource("../../nix/home/quickshell/qml/launcher/Providers.qml");
    }

    // The whole point of the change: the display list is ordered by rank.js
    // rather than by a comparator inlined here. A local sort would keep
    // tst_rank.qml green while ranking nothing.
    function test_results_are_ordered_through_rank_js() {
        const block = Scan.blockAfter(launcherSource(), "readonly property var unfilteredResults: {");
        verify(block !== "", "Launcher must define unfilteredResults");
        verify(block.indexOf("Rank.order(") !== -1, "the display list must be ordered by rank.js's order(), not by a comparator inlined in Launcher.qml");
        verify(block.indexOf("localeCompare") === -1, "the alphabetical tiebreak is what this change removed — it must not survive anywhere in the sort");
    }

    // order() takes the needle already trimmed and already lowercased, and
    // rank.js deliberately does not re-normalise. A caller that forgot would
    // prefix-match nothing for any capitalised query, and every rank.js unit
    // test would still pass.
    function test_the_needle_is_normalised_before_it_reaches_rank_js() {
        const block = Scan.blockAfter(launcherSource(), "readonly property var unfilteredResults: {");
        verify(block.indexOf("toLowerCase()") !== -1, "the needle must be lowercased before order() sees it — rank.js takes it already normalised");
    }

    // The decay stamp has to be refreshed somewhere, and show() is the only
    // moment that is both per-open and not inside a binding.
    function test_the_rank_timestamp_is_refreshed_on_open() {
        const block = Scan.blockAfter(launcherSource(), "function show(): void {");
        verify(block !== "", "Launcher must define show()");
        verify(block.indexOf("root.rankNow = Date.now()") !== -1, "opening the launcher must restamp rankNow, or scores decay against whenever the shell happened to start");
    }

    // Without this the store never gains a single record and the ranking is
    // permanently whatever the seed said.
    function test_activating_a_row_records_the_use() {
        const block = Scan.blockAfter(launcherSource(), "function activate(): void {");
        verify(block !== "", "Launcher must define activate()");
        verify(block.indexOf("providers.recordUse(") !== -1, "activating a row must record the use, or nothing is ever ranked");
        verify(block.indexOf("row.parentKey") !== -1, "the parent key must be passed too, so running an app's action lifts the app itself");
    }

    // beamenu's rule, now covering both filters: rust/beamenu/tests/pills.rs
    // named it editing_the_query_releases_the_engaged_provider. A drill left
    // engaged across a keystroke hides every row the new query matched
    // outside that one app.
    function test_every_keystroke_releases_both_the_pill_and_the_drill() {
        const block = Scan.blockAfter(launcherSource(), "onTextChanged: {");
        verify(block !== "", "the TextInput must define onTextChanged");
        verify(block.indexOf("root.selectedPill = \"\"") !== -1, "editing the query must release the engaged pill");
        verify(block.indexOf("root.drill = null") !== -1, "editing the query must release the drill for the same reason it releases the pill");
    }

    // Escape has to back out of the drill before it closes the window, or
    // there is no keyboard way out of an action list that does not also throw
    // away the query that found it.
    function test_escape_backs_out_of_the_drill_before_closing() {
        const block = Scan.blockAfter(launcherSource(), "Keys.onEscapePressed: {");
        verify(block !== "", "Escape must be a block, since it has two outcomes");
        const drillAt = block.indexOf("root.drillOut()");
        const hideAt = block.indexOf("root.hide()");
        verify(drillAt !== -1, "Escape must leave the drill when one is open");
        verify(hideAt !== -1, "Escape must still close the launcher when no drill is open");
        verify(drillAt < hideAt, "the drill check must come first, or Escape closes the window instead of backing out one level");
    }

    // Right doubles as a caret key. Taking it unconditionally would make the
    // query field impossible to edit anywhere but at its end.
    function test_right_only_drills_with_the_caret_at_the_end() {
        const block = Scan.blockAfter(launcherSource(), "Keys.onRightPressed: (event) => {");
        verify(block !== "", "Right must be handled for drilling in");
        verify(block.indexOf("input.cursorPosition !== input.text.length") !== -1, "Right must yield to the caret unless it is already at the end of the query");
        verify(block.indexOf("event.accepted = false") !== -1, "the non-drilling path must decline the key so the caret still moves");
        verify(block.indexOf("root.drillInto(") !== -1, "Right at the end of the query must drill into the highlighted row");
    }

    // The pointer half of the same gesture, and the reason ResultRow's
    // MouseArea stacking had to change.
    function test_the_row_capsule_reaches_the_drill() {
        const resultRow = readSource("../../nix/home/quickshell/qml/launcher/ResultRow.qml");
        verify(resultRow.indexOf("signal drillRequested") !== -1, "ResultRow must expose a drill signal distinct from activation");
        verify(resultRow.indexOf("onClicked: root.drillRequested()") !== -1, "the action capsule must raise it");

        const mouseAt = resultRow.indexOf("MouseArea {");
        const layoutAt = resultRow.indexOf("RowLayout {");
        verify(mouseAt !== -1 && layoutAt !== -1, "ResultRow must have both a full-row MouseArea and its RowLayout");
        verify(mouseAt < layoutAt, "the full-row MouseArea must be declared BEFORE the RowLayout — later siblings win hit-testing in QML, so declaring it last makes the capsule inside the layout unclickable");

        verify(launcherSource().indexOf("onDrillRequested: {") !== -1, "Launcher must wire the row's drill signal, or the capsule is decorative");
    }

    // The actions moved out of the flat list. One push per matching entry is
    // what "one row per app" means, and it is the thing a later edit could
    // most easily undo without any other test noticing.
    function test_actions_no_longer_land_in_the_flat_list() {
        const block = Scan.blockAfter(providersSource(), "function applicationRows(text: string): var {");
        verify(block !== "", "Providers must define applicationRows");

        // Stated as a structure rather than a count of pushes: the defect
        // being pinned is "actions get iterated into the flat list", which is
        // what a loop over entry.actions containing a push would be. A bare
        // number would also fail the day some unrelated row legitimately
        // joins this provider, and would not say why.
        verify(block.indexOf("for (const action") === -1, "applicationRows must not loop actions into the flat list — that is the shape this change removed");
        verify(block.indexOf("entry.actions.map(") !== -1, "actions must be collected onto the app row instead");

        verify(block.indexOf("actionRows:") !== -1, "the app row must carry its actions");
        verify(block.indexOf("AppsLogic.actionKey(") !== -1, "each action needs its own ranking key");
        verify(block.indexOf("AppsLogic.appKey(") !== -1, "and a parent key pointing back at the app");
    }

    // Hidden on the default screen, reachable by typing. The `text === ""`
    // guard is the whole difference between those two.
    function test_web_apps_are_hidden_only_on_the_empty_query() {
        const block = Scan.blockAfter(providersSource(), "function applicationRows(text: string): var {");
        verify(block.indexOf("AppsLogic.isWebApp(") !== -1, "applicationRows must filter web apps through apps.js");
        verify(block.indexOf("text === \"\" && AppsLogic.isWebApp(") !== -1, "the web-app skip must be guarded on the EMPTY query — unguarded it would make PWAs unreachable by typing, which is not what was asked for");
    }

    // Writing our own file back over the records that produced it, forever.
    function test_the_frecency_store_does_not_watch_itself() {
        const block = Scan.blockAfter(providersSource(), "property var frecencyFile: FileView {");
        verify(block !== "", "Providers must define the frecency FileView");
        verify(block.indexOf("watchChanges") === -1, "the frecency store must not watch its own file — this process is its only writer");
        verify(block.indexOf("atomicWrites: true") !== -1, "it is rewritten whole on every activation, so a torn write would read back as no history at all");
    }

    // The launcher must ship with no opinion about which app you prefer. An
    // earlier draft shipped a Nix-declared seed list naming two browsers, so
    // this pins that it is gone rather than trusting it to stay gone: a
    // preference baked into the tree would quietly outrank real usage on
    // every fresh install.
    function test_no_ranking_preference_is_baked_into_the_shell() {
        const providers = providersSource();
        verify(providers.indexOf("seed") === -1, "Providers must not carry any seeding path — ranking is earned by launching things, never granted");

        const rank = readSource("../../nix/home/quickshell/qml/launcher/rank.js");
        verify(rank.indexOf("seedRecords") === -1, "rank.js must not expose a seeding helper");
        verify(rank.indexOf("librewolf") === -1 && rank.indexOf("brave") === -1, "no application may be named in the ranking logic");
    }
}
