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
        const pills = Pills.pillsFor(rows, rows);

        compare(pills.length, 3);
        compare(pills[0], { id: "apps", label: "Apps", count: 2 });
        compare(pills[1], { id: "status", label: "Status", count: 1 });
        compare(pills[2], { id: "files", label: "Files", count: 1 });
    }

    function test_pillsFor_is_empty_for_no_rows() {
        compare(Pills.pillsFor([], []), []);
    }

    // Major 3: order and counts are read from two different lists on
    // purpose — order from the registry-ordered list a caller never sorts
    // or truncates, counts from whatever list its own filter actually runs
    // against. A provider present in `order` but absent from `counted`
    // (status here, sorted or truncated out of the display list before
    // pillsFor ever sees it) must not appear at all: a pill promising rows
    // it cannot deliver is worse than no pill.
    function test_pillsFor_order_comes_from_first_arg_counts_from_second() {
        const order = [row("apps"), row("status"), row("files")];
        const counted = [row("apps"), row("apps"), row("files")];
        const pills = Pills.pillsFor(order, counted);

        compare(pills.length, 2);
        compare(pills[0], { id: "apps", label: "Apps", count: 2 });
        compare(pills[1], { id: "files", label: "Files", count: 1 });
    }

    // Left-to-right order must survive even when `counted` is sorted into a
    // completely different arrangement — pinning that a caller cannot
    // accidentally restore the pre-fix reordering bug by passing a sorted
    // list as the order source instead of the count source.
    function test_pillsFor_order_is_unaffected_by_counted_arrangement() {
        const order = [row("apps"), row("status"), row("files")];
        const counted = [row("files"), row("status"), row("apps")];
        const pills = Pills.pillsFor(order, counted);

        compare(pills.map(pill => pill.id), ["apps", "status", "files"]);
    }

    // The behaviour the whole split exists for: whatever pillsFor prints as
    // a pill's count, filtering `counted` by that pill's id must yield
    // exactly that many rows — the same list, so clicking a pill can never
    // show a different number than the one printed on it. Modelled on the
    // real bug: `order` is the untruncated registry-order list, `counted`
    // is a display list a 50-row cap already shrank, and one provider
    // (status) did not survive the cut at all.
    function test_pillsFor_count_matches_what_filterByPill_actually_returns() {
        const order = [].concat(
            Array(30).fill(0).map(() => row("apps")),
            Array(20).fill(0).map(() => row("system")),
            Array(5).fill(0).map(() => row("status"))
        );
        // The display list's own 50-row cap: every "apps" row survives, only
        // some of "system" does, and "status" is pushed out entirely.
        const counted = order.slice(0, 45).filter(entry => entry.provider !== "status");
        const pills = Pills.pillsFor(order, counted);

        verify(pills.every(pill => pill.id !== "status"), "a provider with zero surviving rows must not get a pill");

        for (const pill of pills)
            compare(Pills.filterByPill(counted, pill.id).length, pill.count, `pill ${pill.id}'s count must match what clicking it returns`);
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
            { tag: "actions", id: "actions", expected: "Actions" },
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
    // silently vanishing or crashing the bar. And that pill must not be a
    // dead end: clicking it (filterByPill with its id) has to hand back
    // exactly the rows pillsFor counted, the same count-equals-contents
    // invariant test_pillsFor_count_matches_what_filterByPill_actually_returns
    // checks for well-formed rows, asserted here for the providerless case
    // that motivated FALLBACK_PROVIDER in the first place.
    function test_pillsFor_groups_providerless_rows_under_other() {
        const rows = [row("apps"), { title: "mystery row" }, { title: "second mystery row" }];
        const pills = Pills.pillsFor(rows, rows);

        compare(pills.length, 2);
        compare(pills[0], { id: "apps", label: "Apps", count: 1 });
        compare(pills[1], { id: "other", label: "Other", count: 2 });

        for (const pill of pills)
            compare(Pills.filterByPill(rows, pill.id).length, pill.count, `pill ${pill.id}'s count must match what clicking it returns`);
    }
}
