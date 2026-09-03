// rank.js's frecency arithmetic (effectiveScore, bump, evictOverCap,
// seedRecords) and the ranked sort (order) it feeds — plain records and
// fixed timestamps only, no launcher, no FileView-backed frecency.json,
// and no wall clock: every "now" below is a literal so a test's own math
// can be checked by hand instead of racing Date.now().
import QtQuick
import QtTest
import "../../nix/home/quickshell/qml/launcher/rank.js" as Rank

TestCase {
    name: "Rank"

    // rank.js's own HALF_LIFE_MS, restated as a literal rather than read
    // off Rank.HALF_LIFE_MS: this pins the actual required value (one
    // week — see rank.js's header) rather than only checking rank.js
    // agrees with itself, which would still pass if the constant drifted.
    function oneHalfLife() {
        return 7 * 24 * 60 * 60 * 1000;
    }

    function test_effective_score_halves_at_exactly_one_half_life() {
        compare(Rank.HALF_LIFE_MS, oneHalfLife());

        const record = { score: 100, last: 0 };
        compare(Rank.effectiveScore(record, oneHalfLife()), 50);
    }

    function test_bump_accumulates_the_decayed_score_plus_one_data() {
        return [
            { tag: "an existing record decays before accumulating", records: { "apps:foo": { score: 10, last: 0 } }, key: "apps:foo", expected: { score: 6, last: oneHalfLife() } },
            { tag: "a key with no prior record starts from zero", records: {}, key: "apps:bar", expected: { score: 1, last: oneHalfLife() } }
        ];
    }

    function test_bump_accumulates_the_decayed_score_plus_one(row) {
        const next = Rank.bump(row.records, row.key, oneHalfLife());

        compare(next[row.key], row.expected);
    }

    // "Zeta App" carries an astronomically higher frecency score than
    // "Alpha App", but only Alpha's title answers the "alpha" needle —
    // order() must not let any score outweigh a prefix mismatch.
    function test_order_prefix_match_beats_any_score() {
        const rows = [{ title: "Zeta App", key: "apps:zeta" }, { title: "Alpha App", key: "apps:alpha" }];
        const records = { "apps:zeta": { score: 1000000, last: 0 } };

        const ranked = Rank.order(rows, records, "al", 0);

        compare(ranked.map(row => row.title), ["Alpha App", "Zeta App"]);
    }

    // Both rows match the (empty) needle equally, so this isolates the
    // second sort key: "Low" was used most recently but "High" has the
    // higher decayed score, and score has to win.
    function test_order_score_beats_mru() {
        const now = oneHalfLife();
        const rows = [{ title: "Low", key: "apps:low" }, { title: "High", key: "apps:high" }];
        const records = {
            "apps:low": { score: 5, last: now }, // last == now: just used, zero decay
            "apps:high": { score: 100, last: 0 } // one half-life old: decays to 50
        };

        const ranked = Rank.order(rows, records, "", now);

        compare(ranked.map(row => row.title), ["High", "Low"]);
    }

    // Engineered so both records decay to exactly the same effective score
    // (20 * 0.5 == 10 * 1 == 10) despite different (score, last) pairs, so
    // this actually exercises the third sort key rather than one that
    // happens to already agree with it: with eff tied, the more recently
    // used row ("Y", last == now) must win over the older one ("X").
    function test_order_mru_breaks_score_ties() {
        const now = oneHalfLife();
        const rows = [{ title: "X", key: "apps:x" }, { title: "Y", key: "apps:y" }];
        const records = {
            "apps:x": { score: 20, last: 0 },
            "apps:y": { score: 10, last: now }
        };

        compare(Rank.effectiveScore(records["apps:x"], now), Rank.effectiveScore(records["apps:y"], now));

        const ranked = Rank.order(rows, records, "", now);

        compare(ranked.map(row => row.title), ["Y", "X"]);
    }

    // No row here has ever been used (records is empty), so every row ties
    // on prefix, eff and last — the input order, deliberately the reverse
    // of alphabetical, must survive untouched. A regression to sorting by
    // title as a tiebreak would alphabetise this into Apple, Mango, Zebra.
    function test_order_never_used_tail_preserves_anti_alphabetical_input_order() {
        const rows = [{ title: "Zebra" }, { title: "Mango" }, { title: "Apple" }];

        const ranked = Rank.order(rows, {}, "", 0);

        compare(ranked.map(row => row.title), ["Zebra", "Mango", "Apple"]);
    }

    // A row with no `key` property at all and a row whose `key` is absent
    // from `records` both have to score 0 and land at `last` 0 — treated
    // identically, and their relative input order preserved, rather than
    // either one throwing or being singled out.
    function test_order_keyless_rows_rank_zero_in_input_order() {
        const rows = [{ title: "No key property" }, { title: "Dangling key", key: "apps:nowhere" }];

        const ranked = Rank.order(rows, {}, "", 0);

        compare(ranked.map(row => row.title), ["No key property", "Dangling key"]);
    }

    function test_evict_over_cap_keeps_the_highest_scoring_records_up_to_the_cap() {
        compare(Rank.RECORD_CAP, 500);

        const now = 0;
        const records = {
            low: { score: 1, last: now },
            mid: { score: 5, last: now },
            high: { score: 10, last: now }
        };

        const kept = Rank.evictOverCap(records, 2, now);

        compare(Object.keys(kept).sort(), ["high", "mid"]);
    }

    // Ranking is earned, never granted: with nothing recorded, no row can
    // outrank another on score, and the order falls through to the input
    // order the providers produced. This is what replaced the seeded-defaults
    // idea — the launcher ships with no opinion about which app you prefer
    // and forms one only from what you actually launch.
    function test_an_empty_store_ranks_nothing_and_preserves_input_order() {
        const now = 12345;
        const rows = [{ title: "Zed", key: "apps:zed" }, { title: "Alacritty", key: "apps:alacritty" }];

        const ranked = Rank.order(rows, {}, "", now);

        compare(ranked[0].title, "Zed", "an empty store must not reorder anything, not even alphabetically");
        compare(ranked[1].title, "Alacritty");
    }

    function test_functions_do_not_mutate_their_inputs() {
        const now = oneHalfLife();
        const rows = [{ title: "B" }, { title: "A" }];
        const rowsSnapshot = JSON.stringify(rows);
        const records = { "apps:a": { score: 3, last: 0 } };
        const recordsSnapshot = JSON.stringify(records);

        Rank.order(rows, records, "", now);
        compare(JSON.stringify(rows), rowsSnapshot);
        compare(JSON.stringify(records), recordsSnapshot);

        Rank.bump(records, "apps:a", now);
        compare(JSON.stringify(records), recordsSnapshot);

        Rank.evictOverCap(records, 0, now);
        compare(JSON.stringify(records), recordsSnapshot);
    }

    // The change's originating complaint, pinned as the contract that
    // actually replaced it. "Brave Web Browser" sorts before "LibreWolf"
    // alphabetically, and used to win the empty query for that reason alone;
    // it is also first in the *input* rows here, so provider order cannot be
    // what saves LibreWolf either. One launch of LibreWolf is enough to put
    // it on top, and it stays there for as long as it keeps being the one
    // getting used.
    function test_a_launched_app_outranks_an_unused_one_that_sorts_earlier() {
        const now = oneHalfLife();
        const rows = [{ title: "Brave Web Browser", key: "apps:brave-browser" }, { title: "LibreWolf", key: "apps:librewolf" }];

        const records = Rank.bump({}, "apps:librewolf", now);
        const ranked = Rank.order(rows, records, "", now);

        compare(ranked[0].title, "LibreWolf", "the app that has actually been launched must lead the empty query, whatever the alphabet says");
    }

    // The other half of that contract: prefix matching still outranks usage,
    // so heavy LibreWolf use must not make "bra" stop finding Brave. Without
    // this, "rank by what you use" would quietly break search.
    function test_prefix_match_still_beats_a_heavily_used_row() {
        const now = oneHalfLife();
        const rows = [{ title: "LibreWolf", key: "apps:librewolf" }, { title: "Brave Web Browser", key: "apps:brave-browser" }];

        let records = {};
        for (let i = 0; i < 20; i++)
            records = Rank.bump(records, "apps:librewolf", now);

        const ranked = Rank.order(rows, records, "bra", now);

        compare(ranked[0].title, "Brave Web Browser", "typing a prefix must reach the app that starts with it, however much the other one gets used");
    }
}
