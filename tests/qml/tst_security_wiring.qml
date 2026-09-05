// Reachability tests for the Security & privacy page, tst_pill_wiring.qml's
// own pattern: proves settings/pages/security.qml and settings/Settings.qml
// actually wire together the way the task brief requires, not just that
// sandbox/policy.js's pure functions are correct in isolation
// (tst_sandbox_policy.qml already covers that).
//
// qmltestrunner cannot instantiate security.qml or Settings.qml: both reach
// Process/FileView/PanelWindow, Quickshell types tests/README.md rules out —
// so this reads the shipped source as text instead, the same XHR idiom
// tst_pill_wiring.qml and tst_monitor_parity.qml use.
import QtQuick
import QtTest
import "sourcescan.js" as Scan

TestCase {
    name: "SecurityWiring"

    function readSource(relPath) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl(relPath), false);
        xhr.send();
        compare(xhr.status, 200, relPath + " must be readable (needs QML_XHR_ALLOW_FILE_READ=1)");
        return Scan.stripComments(xhr.responseText);
    }

    function securitySource() {
        return readSource("../../nix/home/desktop/quickshell/qml/settings/pages/security.qml");
    }

    function settingsSource() {
        return readSource("../../nix/home/desktop/quickshell/qml/settings/Settings.qml");
    }

    // Settings.qml loads a lowercase-named file by source URL, not an
    // inline tag (a lowercase filename cannot be a QML type name) — and
    // ties its lifetime to the tab itself, so leaving and returning to the
    // page always re-reads dots-sandbox fresh.
    function test_settings_loads_the_security_page_by_source() {
        const src = settingsSource();
        verify(src.indexOf('source: "pages/security.qml"') !== -1, "Settings.qml must Loader-load pages/security.qml by source URL");
        verify(src.indexOf("active: root.showingSecurityPage") !== -1, "the Loader must only be active while the Security tab is selected, so revisiting it re-reads dots-sandbox rather than showing stale data");
    }

    // The stub EmptyState message this page replaces must actually be
    // gone — leaving it behind (even dead, behind a condition that can
    // never be true) is the kind of stale doc a later reader trusts.
    function test_settings_no_longer_calls_security_unbuilt() {
        verify(settingsSource().indexOf("has not been built yet") === -1, "the Security stub message must be removed now that a real page exists");
    }

    // --- The dashboard: pure rendering, no judgement logic ---

    function test_dashboard_reads_report_json() {
        verify(securitySource().indexOf('command: ["dots-sandbox", "report", "--json"]') !== -1, "the dashboard must be driven by dots-sandbox report --json");
    }

    function test_dashboard_renders_cards_in_the_order_the_collector_sent_them() {
        const src = securitySource();
        // report::assemble() already sorts bad-first server-side — a page
        // that re-sorted or filtered `cards` here would be exactly the
        // judgement logic the task brief says belongs in the collector,
        // not this file.
        verify(src.indexOf("model: root.cards") !== -1, "the Repeater must walk root.cards directly");
        verify(src.indexOf(".sort(") === -1, "the page must never re-sort cards — report::assemble() already sorted them bad-first");
        verify(src.indexOf(".filter(") === -1, "the page must never filter cards — every card the collector sent must be shown");
    }

    // Every field a card delegate binds must come straight off
    // modelData — never a hand-rolled comparison like
    // `tpmPresent && !secureBoot` reconstructing a verdict this page has no
    // business computing itself.
    function test_dashboard_card_fields_are_bound_directly() {
        const src = securitySource();
        verify(src.indexOf("card.modelData.title") !== -1);
        verify(src.indexOf("card.modelData.detail") !== -1);
        verify(src.indexOf("card.modelData.rows") !== -1);
        verify(src.indexOf("Policy.toneFor(card.modelData.status)") !== -1, "a card's colour must come from Policy.toneFor(status), the shared pure lookup — not a hand-rolled comparison in this file");
    }

    // common/Pill.qml, per the task brief's own callout to reuse it for
    // every status chip rather than building a parallel capsule.
    function test_dashboard_uses_the_shared_pill() {
        verify(securitySource().indexOf("Pill {") !== -1, "status chips must be built from common/Pill.qml");
    }

    // --- Global permissions: capability-first, Android-permission-manager
    // shape (the task brief's own words: "make permission type buttons
    // that'll lead to apps that requested them"), reading the catalog
    // instead of `policy dump`. ---

    function test_permissions_reads_catalog_json() {
        verify(securitySource().indexOf('command: ["dots-sandbox", "catalog", "--json"]') !== -1, "the permissions list must be driven by dots-sandbox catalog --json, not policy dump");
    }

    // The top level: one row per capability, each leading to its own apps
    // — never the reverse (an app, then its capabilities), which is the
    // shape this page drew before reading the catalog.
    function test_permissions_top_level_groups_by_capability() {
        const src = securitySource();
        verify(src.indexOf("Policy.capabilityGroups(root.catalogSet)") !== -1, "the top-level list must come from Policy.capabilityGroups");
        verify(src.indexOf("root.selectedCapability = capGroupRow.modelData.name") !== -1, "clicking a capability row must drill into that capability's own apps");
    }

    // Drilling into a capability must actually walk that capability's own
    // apps (Policy.appsForCapability), and offer a way back to the
    // top-level list — a drill-in with no way out is a dead end.
    function test_permissions_drill_in_lists_apps_for_the_selected_capability() {
        const src = securitySource();
        verify(src.indexOf("Policy.appsForCapability(root.catalogSet, root.selectedCapability)") !== -1, "the drill-in list must come from Policy.appsForCapability for the SELECTED capability");
        verify(src.indexOf('root.selectedCapability = ""') !== -1, "there must be a way back to the top-level capability list");
    }

    // Exempt apps must appear, marked unsandboxed, at the permissions
    // section's own top level — an invisible exemption list is how a
    // permissions UI starts lying about what it controls.
    // The last link in the reason's chain, and only the last link.
    //
    // A source scan can prove the page reads `.reason`; it cannot prove a
    // real reason ever arrives there, and for a while none did — CatalogEntry
    // had no such field, so this assertion passed against a row that always
    // rendered blank. The two behavioural tests that close that gap are
    // catalog.rs's `an_exempt_app_carries_the_policys_reason_for_exempting_it`
    // (the binary emits it) and tst_sandbox_policy.qml's
    // `test_unconfined_entries_carry_the_policys_reason` (Policy surfaces it).
    // Read all three together; this one alone means very little.
    function test_exempt_apps_show_marked_unsandboxed_with_their_reason() {
        const src = securitySource();
        verify(src.indexOf("Policy.unconfinedEntries(root.catalogSet)") !== -1, "unconfined apps must come from Policy.unconfinedEntries");
        verify(src.indexOf('text: "No sandbox"') !== -1, "an exempt app's row must say it is unsandboxed, not just omit the usual controls");
        verify(src.indexOf("unconfinedRow.modelData.reason") !== -1, "an exempt app's row must show the policy's own reason string");
    }

    // The capability vocabulary must come from the binary, never from a
    // table in QML.
    //
    // policy.js used to carry its own `CAPABILITIES` array of name+label
    // pairs mirroring policy.rs's `Capability::ALL`. That is a second source
    // of truth: renaming or adding a capability in Rust left the QML stale,
    // the page then showed an old name or silently omitted the capability,
    // and nothing anywhere failed. `catalog --json` now publishes the
    // vocabulary and policy.js reads it, so this guards the table not
    // growing back.
    function test_the_capability_vocabulary_is_not_restated_in_qml() {
        const policySrc = readSource("../../nix/home/desktop/quickshell/qml/sandbox/policy.js");

        verify(policySrc.indexOf("capabilityVocabulary") !== -1,
               "policy.js must read the vocabulary the catalog published");

        // The give-away shape: an argv-spelled capability name sitting next
        // to a human label in the QML itself.
        for (const name of ["net", "nix-daemon", "repo-read", "repo-write", "postgres", "settings-ro", "kvm"]) {
            verify(policySrc.indexOf('{ name: "' + name + '", label:') === -1,
                   "policy.js must not restate a label for '" + name + "' — that table drifts from policy.rs silently");
        }
    }

    // Every capability toggle must be a real three-state control
    // (controls/Segmented.qml, per the task brief's own reuse callout),
    // wired to setCapability — which itself must never touch
    // overridesFile.adapter directly (see settings/pages/security.qml's own
    // overridesRoot comment for why that specific split matters to
    // qmllint), and must re-read the catalog afterwards rather than only
    // guessing at the merged result.
    function test_capability_toggle_writes_through_the_overrides_file() {
        const src = securitySource();
        verify(src.indexOf("Segmented {") !== -1, "capability state must be edited through controls/Segmented.qml, not a parallel three-way control");
        verify(src.indexOf("onActivated: value => root.setCapability(") !== -1, "flipping a segment must call setCapability");

        const setCapability = Scan.blockAfter(src, "function setCapability(appId: string, capability: string, state: string): void {");
        verify(setCapability !== "", "setCapability must be a real function");
        verify(setCapability.indexOf("Policy.withCapabilityOverride(root.overridesRoot") !== -1, "the write must narrow through Policy.withCapabilityOverride, never replace the whole overrides file");
        verify(setCapability.indexOf("overridesFile.setText(") !== -1, "the merged document must actually be written back");
        verify(setCapability.indexOf("catalogProc.running = true") !== -1, "the permissions list must re-read the catalog after a write, to show the MERGED resolved state rather than an optimistic guess");
    }

    // The three-way control is a non-negotiable: a previous attempt at
    // this page replaced Allow/Ask/Deny with a two-state toggle and
    // silently deleted the "ask" state — the state that makes an app
    // prompt at all. Pinned directly rather than trusted to survive by
    // implication of the Segmented check above.
    function test_capability_control_stays_three_way() {
        const src = securitySource();
        verify(src.indexOf('{ label: "Allow", value: "allow" }') !== -1, "the Allow option must survive");
        verify(src.indexOf('{ label: "Ask", value: "ask" }') !== -1, "the Ask option must survive — this is the state a two-state toggle silently deletes");
        verify(src.indexOf('{ label: "Deny", value: "deny" }') !== -1, "the Deny option must survive");
    }

    // Every app row in the drill-in must say whether it needs a relaunch —
    // marking NOTHING here (an editable toggle with no caveat at all)
    // would read as "this applies immediately", which
    // rust/dots-sandbox/src/argv.rs's spawn-time-only binds make untrue
    // for all seven known capabilities.
    function test_every_capability_row_carries_a_relaunch_caveat() {
        const src = securitySource();
        verify(src.indexOf("Policy.needsRelaunch(root.selectedCapability)") !== -1, "each app row's relaunch caveat must come from the shared Policy.needsRelaunch lookup");
        verify(src.indexOf("Applies on next launch") !== -1, "an app row must say its change applies on the next launch, not to a copy already running");
    }

    // The revocation-stops-new-access-only fact, said where a user
    // deciding whether to trust a revoked capability can actually see it.
    function test_permissions_section_states_revocation_only_blocks_new_access() {
        verify(securitySource().indexOf("only blocks NEW access") !== -1, "the page must say that turning a capability off does not reach into a file the app already has open");
    }
}
