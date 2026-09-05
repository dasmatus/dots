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

    // --- Global permissions ---

    function test_permissions_reads_policy_dump() {
        verify(securitySource().indexOf('command: ["dots-sandbox", "policy", "dump"]') !== -1, "the permissions list must be driven by dots-sandbox policy dump");
    }

    // Exempt apps must appear, marked unsandboxed, with the policy's own
    // reason string shown — an invisible exemption list is how a
    // permissions UI starts lying about what it controls.
    function test_exempt_apps_show_marked_unsandboxed_with_their_reason() {
        const src = securitySource();
        verify(src.indexOf('appBlock.modelData.kind === "unconfined"') !== -1, "an unconfined app must get its own visible row");
        verify(src.indexOf('title: "Unsandboxed"') !== -1, "an exempt app's row must say it is unsandboxed, not just omit the usual controls");
        verify(src.indexOf("appBlock.modelData.reason") !== -1, "an exempt app's row must show the policy's own reason string");
    }

    // Every capability toggle must be a real three-state control
    // (controls/Segmented.qml, per the task brief's own reuse callout),
    // wired to setCapability — which itself must never touch
    // overridesFile.adapter directly (see settings/pages/security.qml's own
    // overridesRoot comment for why that specific split matters to
    // qmllint), and must re-read policy dump afterwards rather than only
    // guessing at the merged result.
    function test_capability_toggle_writes_through_the_overrides_file() {
        const src = securitySource();
        verify(src.indexOf("Segmented {") !== -1, "capability state must be edited through controls/Segmented.qml, not a parallel three-way control");
        verify(src.indexOf("onActivated: value => root.setCapability(") !== -1, "flipping a segment must call setCapability");

        const setCapability = Scan.blockAfter(src, "function setCapability(appId: string, capability: string, state: string): void {");
        verify(setCapability !== "", "setCapability must be a real function");
        verify(setCapability.indexOf("Policy.withCapabilityOverride(root.overridesRoot") !== -1, "the write must narrow through Policy.withCapabilityOverride, never replace the whole overrides file");
        verify(setCapability.indexOf("overridesFile.setText(") !== -1, "the merged document must actually be written back");
        verify(setCapability.indexOf("policyProc.running = true") !== -1, "the permissions list must re-read policy dump after a write, to show the MERGED resolved state rather than an optimistic guess");
    }

    // Every capability row must say whether it needs a relaunch — marking
    // NOTHING here (an editable toggle with no caveat at all) would read
    // as "this applies immediately", which rust/dots-sandbox/src/argv.rs's
    // spawn-time-only binds make untrue for all seven known capabilities.
    function test_every_capability_row_carries_a_relaunch_caveat() {
        const src = securitySource();
        verify(src.indexOf("Policy.needsRelaunch(capRow.modelData.name)") !== -1, "each capability row's relaunch caveat must come from the shared Policy.needsRelaunch lookup");
        verify(src.indexOf("Applies on next launch") !== -1, "a capability row must say its change applies on the next launch, not to a copy already running");
    }

    // The revocation-stops-new-access-only fact, said where a user
    // deciding whether to trust a revoked capability can actually see it.
    function test_permissions_section_states_revocation_only_blocks_new_access() {
        verify(securitySource().indexOf("only blocks NEW access") !== -1, "the page must say that turning a capability off does not reach into a file the app already has open");
    }
}
