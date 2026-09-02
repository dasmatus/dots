// The launcher's filter pill bar, restoring the contract
// rust/beamenu/src/item.rs documented on `Item::provider`: "every provider
// owns exactly one pill that filters to its own rows." Plain row arrays only
// — no PanelWindow, MouseArea or live query anywhere near this test.
import QtQuick
import QtTest
import "../../nix/home/quickshell/qml/launcher/pills.js" as Pills

TestCase {
    name: "Pills"

    function row(provider) {
        return { title: provider, provider: provider };
    }

    function test_pillsFor_counts_one_pill_per_provider_in_first_seen_order() {
        const rows = [row("apps"), row("apps"), row("status"), row("files")];
        const pills = Pills.pillsFor(rows);

        compare(pills.length, 3);
        compare(pills[0], { id: "apps", label: "Apps", count: 2 });
        compare(pills[1], { id: "status", label: "Status", count: 1 });
        compare(pills[2], { id: "files", label: "Files", count: 1 });
    }

    function test_pillsFor_is_empty_for_no_rows() {
        compare(Pills.pillsFor([]), []);
    }

    function test_filterByPill_keeps_only_the_selected_providers_rows() {
        const rows = [row("apps"), row("status"), row("apps")];
        const filtered = Pills.filterByPill(rows, "apps");

        compare(filtered.length, 2);
        verify(filtered.every(entry => entry.provider === "apps"));
    }

    function test_filterByPill_empty_selection_is_the_all_state() {
        const rows = [row("apps"), row("status")];

        compare(Pills.filterByPill(rows, ""), rows);
    }

    // rust/beamenu/tests/pills.rs named this
    // an_engaged_provider_with_no_rows_reports_no_pill_rather_than_the_first:
    // a selection pointing at a provider absent from the current rows must
    // report nothing, never silently fall back to whichever provider
    // happens to be first — that would show apps' rows while the pill bar
    // still claimed "status" was engaged.
    function test_filterByPill_a_provider_with_no_rows_is_empty_not_the_first_providers_rows() {
        const rows = [row("apps"), row("apps")];
        const filtered = Pills.filterByPill(rows, "status");

        compare(filtered, []);
        verify(filtered !== rows);
    }

    function test_labelFor_known_providers_data() {
        return [
            { tag: "apps", id: "apps", expected: "Apps" },
            { tag: "status", id: "status", expected: "Status" },
            { tag: "websearch", id: "websearch", expected: "Web" }
        ];
    }

    function test_labelFor_known_providers(row) {
        compare(Pills.labelFor(row.id), row.expected);
    }

    // A plugin or provider added later without an entry in LABELS still gets
    // a readable pill instead of a blank or raw-id one.
    function test_labelFor_falls_back_to_a_capitalised_id() {
        compare(Pills.labelFor("mystery"), "Mystery");
    }

    // Motivating bug: deviceRows() built rows with no `provider` field at
    // all, so labelFor(undefined) fell through to `id.length` and threw —
    // and a QML binding that throws evaluates to undefined, which took down
    // the whole pill bar rather than just the one malformed row. labelFor
    // must return a label for anything it is handed, never throw.
    function test_labelFor_is_total_data() {
        return [
            { tag: "undefined", id: undefined },
            { tag: "null", id: null },
            { tag: "number", id: 42 },
            { tag: "empty string", id: "" }
        ];
    }

    function test_labelFor_is_total(row) {
        compare(Pills.labelFor(row.id), "Other");
    }

    // A row missing `provider` — deviceRows()'s exact shape of bug before it
    // was fixed to set one — must not throw pillsFor's caller into
    // `undefined`. It groups under one visible "Other" pill instead of
    // silently vanishing or crashing the bar.
    function test_pillsFor_groups_providerless_rows_under_other() {
        const rows = [row("apps"), { title: "mystery row" }, { title: "second mystery row" }];
        const pills = Pills.pillsFor(rows);

        compare(pills.length, 2);
        compare(pills[0], { id: "apps", label: "Apps", count: 1 });
        compare(pills[1], { id: "other", label: "Other", count: 2 });
    }
}
