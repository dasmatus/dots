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
        return readSource("../../nix/home/desktop/quickshell/qml/launcher/Launcher.qml");
    }

    function providersSource() {
        return readSource("../../nix/home/desktop/quickshell/qml/launcher/Providers.qml");
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

    // The other half of that rule, and the one a regression would reach for
    // first. A QML binding does not re-evaluate because time passed, so
    // reading the clock inside the sort means the keystrokes that happen to
    // re-run it decay against a different `now` than the ones that do not,
    // and rows minutes apart can swap places mid-typing. Nothing about the
    // observable behaviour of a single keystroke would look wrong, which is
    // why it needs pinning here rather than in a unit test.
    function test_the_sort_never_reads_the_clock_itself() {
        const block = Scan.blockAfter(launcherSource(), "readonly property var unfilteredResults: {");
        verify(block.indexOf("Date.now()") === -1, "the sort must decay against the stamp taken in show(), never read the clock inside a binding");
        verify(block.indexOf("root.rankNow") !== -1, "it must use that stamp");
    }

    // Without this the store never gains a single record and every row ranks
    // 0 forever, which looks exactly like the launcher working.
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

    function resultRowSource() {
        return readSource("../../nix/home/desktop/quickshell/qml/launcher/ResultRow.qml");
    }

    // The pointer half of drilling in, after the capsule moved off the rows
    // and into the pill bar. What used to be a three-link chain — ResultRow's
    // `signal drillRequested`, its capsule raising it, and Launcher relaying
    // through `onDrillRequested` — is now one capsule calling drillInto in the
    // scope that owns it, so this pins the new place instead of the old one.
    //
    // Position is asserted, not just presence: a capsule that reaches
    // drillInto from anywhere in the file would satisfy a bare indexOf while
    // sitting back on the row, which is the exact arrangement this change
    // exists to undo.
    function test_the_pill_bar_capsule_reaches_the_drill() {
        const src = launcherSource();

        const barAt = src.indexOf("id: pillRow");
        const listAt = src.indexOf("ListView {");
        verify(barAt !== -1, "Launcher must still declare the pill bar as pillRow");
        verify(listAt !== -1 && listAt > barAt, "the result list must still follow the pill bar");

        const bar = src.slice(barAt, listAt);
        verify(bar.indexOf("root.actionPills") !== -1, "the drill capsules must live between the search field and the list, built from the actionPills model");
        verify(bar.indexOf("root.drillInto(") !== -1, "a capsule must reach drillInto directly — there is no per-row signal left to relay through");

        // Next to the provider pills means AFTER them: the capsule is what the
        // Apps and Actions pills are read alongside, not something that pushes
        // them rightwards off the bar's left edge.
        const providerAt = src.indexOf("delegate: Pill {");
        verify(providerAt !== -1 && providerAt < src.indexOf("root.drillInto(", barAt), "the capsule must be declared after the provider-pill Repeater, so it sits beside the provider pills rather than ahead of them");
    }

    // The capsule shares the bar with the filter pills but is not one, and
    // nothing about it may leak into the list Tab walks. pillsFor's contract
    // is one pill per provider; a drill capsule folded into root.pills would
    // break that and give Tab a stop that filters nothing.
    function test_the_capsule_stays_out_of_the_filter_cycle() {
        const src = launcherSource();

        const cycle = Scan.blockAfter(src, "function cyclePill(delta: int): void {");
        verify(cycle !== "", "Launcher must define cyclePill");
        verify(cycle.indexOf("root.pills.map(") !== -1, "Tab must cycle root.pills alone");
        verify(cycle.indexOf("actionPills") === -1, "the drill capsules must not be reachable by Tab — they are actions, not filters");

        const pillsAt = src.indexOf("readonly property var pills:");
        const resultsAt = src.indexOf("readonly property var results:");
        verify(pillsAt !== -1 && resultsAt > pillsAt, "Launcher must define pills and then results");
        verify(src.slice(pillsAt, resultsAt).indexOf("actionPills") === -1, "the capsules must not be entries in root.pills either, or the provider Repeater would draw them a second time");
    }

    // The row is a row again: it draws what it is and carries no control of
    // its own. Asserting the absence, not just the bar's presence, is what
    // stops the capsule being reintroduced on the row alongside the one in
    // the bar and quietly leaving two ways to do the same thing.
    function test_the_row_carries_no_capsule_of_its_own() {
        const resultRow = resultRowSource();

        verify(resultRow.indexOf("drillRequested") === -1, "the drill signal must be gone from the row, not merely unused");
        verify(resultRow.indexOf("actionCount") === -1, "the row must no longer take an action count it has nothing to draw with");
        verify(resultRow.indexOf("Pill") === -1, "the row must instantiate no capsule at all — every one of them is in the bar now");
    }

    // "All apps' actions", not the highlighted one's: one capsule per app in
    // the visible list that has any. Built from `results` rather than from the
    // untruncated ambient list for the reason pillsFor takes its counts from
    // unfilteredResults — a capsule promising rows the list does not have is a
    // control that cannot keep its word.
    function test_every_app_with_actions_gets_a_capsule() {
        const block = Scan.blockAfter(launcherSource(), "readonly property var actionPills: {");
        verify(block !== "", "Launcher must define actionPills");

        verify(block.indexOf("root.results") !== -1, "the capsules must be built from the list actually on screen");
        verify(block.indexOf("actionCount") !== -1, "an app earns a capsule by having actions, so the count is what selects it");
        verify(block.indexOf("root.drill") !== -1, "a drill must clear the capsules — the bar is then showing one pill that stands for the drill itself");
    }

    // The launcher's other complaint fixed alongside the tray: a drill
    // capsule ("LibreWolf · 3 actions") used to be text only, even though the
    // row it replaced carried the app's own icon. Provider pills (Apps,
    // Actions, System) are deliberately left out of this — the agreed shape
    // keeps them text-only, so the first `delegate: Pill {` block (theirs)
    // must show no Image while the action delegate's does.
    function test_action_capsules_carry_their_apps_icon() {
        const src = launcherSource();

        const pillsBlock = Scan.blockAfter(src, "readonly property var actionPills: {");
        verify(pillsBlock !== "", "Launcher must define actionPills");
        verify(pillsBlock.indexOf("icon:") !== -1, "each capsule's model entry must carry the row's own icon, or the delegate has nothing to show");

        const providerDelegate = Scan.blockAfter(src, "delegate: Pill {");
        verify(providerDelegate !== "", "the provider pill delegate must exist");
        verify(providerDelegate.indexOf("Image") === -1, "provider pills (Apps/Actions/System) stay text-only — only the drill capsules gained an icon");

        const actionAt = src.indexOf("id: actionDelegate");
        const listAt = src.indexOf("ListView {");
        verify(actionAt !== -1 && listAt !== -1 && listAt > actionAt, "the action-pill delegate must be declared before the result list");

        const actionDelegate = src.slice(actionAt, listAt);
        verify(actionDelegate.indexOf("Image {") !== -1, "the action-pill delegate must draw an Image for the app's icon");
        verify(actionDelegate.indexOf("actionDelegate.modelData.icon") !== -1, "the Image must be fed from the model's own icon");
        verify(actionDelegate.indexOf("sourceSize") !== -1, "the icon must set sourceSize, the crisp-SVG idiom ResultRow and FocusedWindow already use");
        verify(actionDelegate.indexOf("visible:") !== -1, "the icon must be guarded by visible:, so an app with no resolvable icon degrades to a text-only capsule instead of a blank square");
        verify(actionDelegate.indexOf("anchors.verticalCenter") !== -1, "the icon and label must be vertically centred — Pill's internal Row manages only the horizontal axis, so an unset icon and label top-align once the icon outgrows the text");
    }

    // Kept from the arrangement the capsules left behind. Nothing inside the
    // row's layout asks for its own clicks today, so this no longer guards a
    // live case — it guards the next one, and it is cheaper to hold than to
    // rediscover.
    function test_the_full_row_mousearea_stays_under_the_layout() {
        const resultRow = resultRowSource();

        const mouseAt = resultRow.indexOf("MouseArea {");
        const layoutAt = resultRow.indexOf("RowLayout {");
        verify(mouseAt !== -1 && layoutAt !== -1, "ResultRow must have both a full-row MouseArea and its RowLayout");
        verify(mouseAt < layoutAt, "the full-row MouseArea must be declared BEFORE the RowLayout — later siblings win hit-testing in QML, so declaring it last would make anything clickable added inside the layout unclickable");
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

    // Task 10: desktop actions used to reach the flat list nowhere except
    // nested under their app's own actionRows:, so rank.js never scored them
    // and pills.js never counted them — typing an action's own name, like
    // "compose" for Mastodon's "Compose new post", found nothing outside
    // drilling into the app first. appActionRows is the fix; this pins that
    // the ambient chain actually calls it, and after applicationRows rather
    // than before, since Launcher.qml's comment on unfilteredResults says the
    // final tiebreak on the row's original index is what keeps an action
    // below its own app when both score equally — appending rather than
    // prepending is the whole mechanism.
    function test_app_actions_reach_the_ambient_chain_after_applications() {
        const block = Scan.blockAfter(launcherSource(), "readonly property var ambientRows: {");
        verify(block !== "", "Launcher must define ambientRows");
        verify(block.indexOf("providers.appActionRows(") !== -1, "the ambient chain must call the app-actions provider, or actions stay unreachable outside drill-in");

        const appsAt = block.indexOf("providers.applicationRows(");
        const actionsAt = block.indexOf("providers.appActionRows(");
        verify(appsAt !== -1, "applicationRows must still be called");
        verify(appsAt < actionsAt, "appActionRows must be concatenated AFTER applicationRows, not before — that ordering is the whole tiebreak mechanism");
    }

    // The mirror of the test above, for the provider a hand-resolved merge
    // conflict in this same concat chain could just as easily have dropped:
    // appActionRows had test_app_actions_reach_the_ambient_chain_after_
    // applications pinning its presence, keyboardRows had no such test, so
    // losing it from the chain was (and would again be) a green build with
    // every layout-switch row silently unreachable outside a query that
    // happens to match one of keyboard.js's own KEYWORDS by accident.
    function test_keyboard_rows_reach_the_ambient_chain() {
        const block = Scan.blockAfter(launcherSource(), "readonly property var ambientRows: {");
        verify(block !== "", "Launcher must define ambientRows");
        verify(block.indexOf("providers.keyboardRows(") !== -1, "the ambient chain must call the keyboard-layout provider, or its rows are unreachable");
    }

    // Every remaining link in that chain, table-driven, because the two tests
    // above only cover the two providers that happened to get one. Removing
    // ONE call from a nine-call concat expression is a one-token edit in the
    // middle of a very long line, and it has now happened twice: keyboardRows
    // to a merge, and snippetRows to an edit that meant to pull fileRows out
    // and took its neighbour with it. Neither surfaced as anything but a
    // feature quietly not working.
    function test_every_ambient_provider_is_still_called_data() {
        return [
            { tag: "applications", call: "providers.applicationRows(" },
            { tag: "app actions", call: "providers.appActionRows(" },
            { tag: "system", call: "providers.systemRows(" },
            { tag: "keyboard", call: "providers.keyboardRows(" },
            { tag: "quicklinks", call: "providers.quicklinkRows(" },
            { tag: "snippets", call: "providers.snippetRows(" },
            { tag: "devices", call: "providers.deviceRows(" },
            { tag: "status", call: "providers.statusRows(" }
        ];
    }

    function test_every_ambient_provider_is_still_called(row) {
        const block = Scan.blockAfter(launcherSource(), "readonly property var ambientRows: {");
        verify(block !== "", "Launcher must define ambientRows");
        verify(block.indexOf(row.call) !== -1, "the ambient chain must call " + row.call + " — dropping it makes every one of that provider's rows unreachable, with nothing else failing to say so");
    }

    // The inverse of the two tests above, and the reason it needs one at all:
    // every other provider's bug is being dropped from the chain, and files'
    // is being put back into it. Three characters of any query used to reach
    // fd, so typing an app's name paid for a filesystem search and then showed
    // it alongside the app. Files answer to a prefix now, like windows,
    // clipboard and emoji — and a merge that "restored" the concat would be a
    // green build that silently reinstated both halves of that.
    function test_files_answer_to_a_prefix_and_stay_out_of_the_ambient_chain() {
        const src = launcherSource();
        const block = Scan.blockAfter(src, "readonly property var ambientRows: {");
        verify(block !== "", "Launcher must define ambientRows");

        verify(block.indexOf('text.startsWith("f ")') !== -1, "files must have a prefix branch of their own, or the provider is unreachable entirely");

        const chainAt = block.indexOf("return providers.applicationRows(");
        verify(chainAt !== -1, "the ambient concat chain must still exist");
        verify(block.slice(chainAt).indexOf("providers.fileRows(") === -1, "fileRows must not be concatenated into the ambient chain — a query about an app must not also be a filesystem search");

        verify(src.indexOf('providers.fileQuery = input.text.startsWith("f ")') !== -1, "fd must only be fed by a query that asked for it, not by every query that reached three characters");

        const prefixed = src.indexOf('text.startsWith("=") || text.startsWith("?")');
        verify(prefixed !== -1, "unfilteredResults must still list the prefixed queries it declines to re-sort");
        verify(src.slice(prefixed, prefixed + 200).indexOf('text.startsWith("f ")') !== -1, "the files prefix must join that list too, or a single provider's own list gets re-sorted as though it were the ambient one");
    }

    // The new provider's own shape: it must earn the same frecency keys the
    // nested actionRows: already use — tst_launcher_wiring.qml:82 pins that
    // activate() forwards parentKey, so a mismatch here would leave that
    // wiring pointing at a row nothing ever produces — and it must carry its
    // own provider id rather than "apps", or pills.js's pillsFor would fold
    // it into the Apps pill instead of counting it apart.
    function test_app_action_rows_carry_the_right_keys_and_provider() {
        const block = Scan.blockAfter(providersSource(), "function appActionRows(text: string): var {");
        verify(block !== "", "Providers must define appActionRows");

        verify(block.indexOf("AppsLogic.actionKey(") !== -1, "each action row needs its own ranking key, the same one actionRows: already uses");
        verify(block.indexOf("AppsLogic.appKey(") !== -1, "and a parentKey pointing back at the app, so activating it also lifts the app's own frecency");
        verify(block.indexOf("provider: \"actions\"") !== -1, "the row must carry its own provider id, not \"apps\", or pills.js cannot count it apart from the app it belongs to");
    }

    // Hidden on the default screen, reachable by typing. The `text === ""`
    // guard is the whole difference between those two.
    function test_web_apps_are_hidden_only_on_the_empty_query() {
        const block = Scan.blockAfter(providersSource(), "function applicationRows(text: string): var {");
        verify(block.indexOf("AppsLogic.isWebApp(") !== -1, "applicationRows must filter web apps through apps.js");
        verify(block.indexOf("text === \"\" && AppsLogic.isWebApp(") !== -1, "the web-app skip must be guarded on the EMPTY query — unguarded it would make PWAs unreachable by typing, which is not what was asked for");
    }

    // The same guard, mirrored onto the actions provider so it cannot drift
    // out of step with applicationRows. A PWA hidden from the empty-query
    // screen must not have an Actions= group on that same .desktop file
    // reopen the door — that row's subtitle would carry the hidden app's own
    // name, which is exactly the noise the guard exists to keep out.
    function test_app_action_rows_hide_web_apps_only_on_the_empty_query() {
        const block = Scan.blockAfter(providersSource(), "function appActionRows(text: string): var {");
        verify(block !== "", "Providers must define appActionRows");
        verify(block.indexOf("AppsLogic.isWebApp(") !== -1, "appActionRows must filter web apps through apps.js, the same as applicationRows");
        verify(block.indexOf("text === \"\" && AppsLogic.isWebApp(") !== -1, "the web-app skip must be guarded on the EMPTY query here too — unguarded it would make a PWA's actions unreachable by typing");
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

        const rank = readSource("../../nix/home/desktop/quickshell/qml/launcher/rank.js");
        verify(rank.indexOf("seedRecords") === -1, "rank.js must not expose a seeding helper");
        verify(rank.indexOf("librewolf") === -1 && rank.indexOf("brave") === -1, "no application may be named in the ranking logic");
    }
}
