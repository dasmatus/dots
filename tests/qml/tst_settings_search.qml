// Settings search arithmetic (nix/home/desktop/quickshell/qml/settings/search.js).
//
// The fixture below is shaped to exercise page/group granularity, not just
// "some rows matched": "network" hits Hostname (identity/identity-machine)
// and Ollama (ai/ai-providers) — two rows in two different pages — while
// leaving Git name (identity/identity-profile) and Claude Code
// (ai/ai-providers) unmatched. That makes identity-profile a group whose
// rows all failed sitting right beside identity-machine, a group in the
// very same page whose row passed — proof that a group hides on its own
// rows, not on whether its page had any luck at all.
import QtQuick
import QtTest
import "../../nix/home/desktop/quickshell/qml/settings/search.js" as Search

TestCase {
    name: "SettingsSearch"

    function fixtureRows() {
        return [
            {
                id: "gitName",
                pageId: "identity",
                groupId: "identity-profile",
                title: "Git name",
                description: "Used for commit authorship"
            },
            {
                id: "hostname",
                pageId: "identity",
                groupId: "identity-machine",
                title: "Hostname",
                description: "Answers to this on the network"
            },
            {
                id: "aiOllama",
                pageId: "ai",
                groupId: "ai-providers",
                title: "Ollama",
                description: "Runs models on this network with no cloud involved"
            },
            {
                id: "aiClaude",
                pageId: "ai",
                groupId: "ai-providers",
                title: "Claude Code",
                description: "A cloud coding agent"
            }
        ];
    }

    // An untouched search field restores every row, group and page — the
    // state Settings.qml must render identically to no search having run at
    // all.
    function test_empty_query_restores_everything() {
        const result = Search.search(fixtureRows(), "");

        compare(result.matchedIds.length, 4, "an empty query must match every row");
        compare(result.visibleGroupIds.length, 3, "an empty query must leave every group visible");
        compare(result.visiblePageIds.length, 2, "an empty query must leave every page visible");
        compare(result.empty, false, "an empty query is not the empty state");
    }

    // A query that matches nothing at all is the one case the empty state
    // exists for.
    function test_query_matching_nothing_yields_empty_state() {
        const result = Search.search(fixtureRows(), "zzz-nonexistent");

        compare(result.matchedIds.length, 0);
        compare(result.visibleGroupIds.length, 0);
        compare(result.visiblePageIds.length, 0);
        compare(result.empty, true, "a real query matching nothing must report the empty state");
    }

    // "network" is the fixture's cross-page needle: Hostname (identity) and
    // Ollama (ai) both carry it in their description, and neither page's
    // name mentions it.
    function test_query_matches_rows_in_two_different_pages() {
        const result = Search.search(fixtureRows(), "network");

        compare(result.matchedIds.sort(), ["aiOllama", "hostname"].sort());
        compare(result.visiblePageIds.sort(), ["ai", "identity"].sort(), "the match must be attributed to both pages that carry it");
        compare(result.empty, false);
    }

    // identity-profile (Git name) has no "network" in it; identity-machine
    // (Hostname), its sibling group under the very same identity page, does.
    // A group hiding on its OWN rows rather than on its page's overall luck
    // is the property this pins.
    function test_group_with_no_matching_rows_hides_itself() {
        const result = Search.search(fixtureRows(), "network");

        verify(result.visibleGroupIds.indexOf("identity-machine") !== -1, "identity-machine must stay visible — its own row matched");
        verify(result.visibleGroupIds.indexOf("identity-profile") === -1, "identity-profile must hide — none of its own rows matched, even though its page did");
        verify(result.visiblePageIds.indexOf("identity") !== -1, "the identity page itself must stay visible — one of its groups still matched");
    }

    function test_matching_is_case_insensitive_data() {
        return [
            { tag: "shouty needle", query: "OLLAMA", expectedId: "aiOllama" },
            { tag: "shouty title", query: "git NAME", expectedId: "gitName" },
            { tag: "mixed case in description", query: "CoDiNg AgEnT", expectedId: "aiClaude" }
        ];
    }

    function test_matching_is_case_insensitive(row) {
        const result = Search.search(fixtureRows(), row.query);
        verify(result.matchedIds.indexOf(row.expectedId) !== -1, row.tag + ": expected " + row.expectedId + " to match \"" + row.query + "\"");
    }

    // rowMatches itself, the seam search() is built on: an empty needle
    // matches unconditionally, and the description and keywords fields
    // count exactly as much as the title.
    function test_rowMatches_data() {
        return [
            { tag: "empty needle matches", row: { title: "Anything" }, needle: "", expected: true },
            { tag: "title match", row: { title: "Hostname" }, needle: "host", expected: true },
            { tag: "description match", row: { title: "X", description: "network settings" }, needle: "network", expected: true },
            { tag: "keywords match", row: { title: "X", keywords: "wifi wireless" }, needle: "wifi", expected: true },
            { tag: "no match anywhere", row: { title: "X", description: "Y", keywords: "Z" }, needle: "nope", expected: false }
        ];
    }

    function test_rowMatches(row) {
        compare(Search.rowMatches(row.row, row.needle), row.expected, row.tag);
    }
}
