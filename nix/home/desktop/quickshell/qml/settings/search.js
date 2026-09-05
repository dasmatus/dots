// Pure filter arithmetic behind the settings search field.
//
// Split out for the same reason bar/battery.js and launcher/rank.js are:
// Settings.qml reaches PanelWindow, WlrLayershell and IpcHandler, all
// Quickshell types qmltestrunner cannot load (tests/README.md), so the one
// part of "typing narrows the list" worth unit-testing at all has to live
// somewhere that isn't inside it.
//
// A "row descriptor" is a plain object, never a live SettingsRow instance:
// { id, pageId, groupId, title, description, keywords }. Settings.qml builds
// one per SettingsRow it renders — real ones for Identity, none yet for the
// still-stubbed pages — and hands the flat array here on every keystroke.
// Nothing in this file reaches back into QML to read a property off a
// component, which is what keeps it instantiable with no compositor, no
// Theme and no Settings.qml at all.
.pragma library

// Whether one row matches an already-trimmed, already-lowercased needle. An
// empty needle matches every row, which is what lets search() below answer
// "no query yet" without a separate branch for it — matchedIds ends up the
// full row list on its own.
function rowMatches(row, needle) {
    if (needle === "")
        return true;

    const haystack = `${row.title ?? ""} ${row.description ?? ""} ${row.keywords ?? ""}`.toLowerCase();
    return haystack.indexOf(needle) !== -1;
}

// The whole search: which rows matched, and which of the groups and pages
// that hold them still have something to show as a result.
//
// Groups and pages are derived from the rows themselves rather than passed
// in as separate lists, on purpose: a group or page that owns no rows at
// all — every one of today's still-stubbed nav pages — never appears in
// either output and so can never be mistaken for a group a real search
// emptied out. Settings.qml tells the two apart by checking its own static
// page list instead, which is exactly the distinction the stubbed pages'
// own "not built yet" placeholder needs.
function search(rows, query) {
    const needle = query.trim().toLowerCase();

    const matchedIds = [];
    const matchedGroupIds = new Set();
    const matchedPageIds = new Set();

    for (const row of rows) {
        if (!rowMatches(row, needle))
            continue;

        matchedIds.push(row.id);
        matchedGroupIds.add(row.groupId);
        matchedPageIds.add(row.pageId);
    }

    return {
        matchedIds: matchedIds,
        visibleGroupIds: Array.from(matchedGroupIds),
        visiblePageIds: Array.from(matchedPageIds),
        // Only a real query can produce the empty state. An empty query
        // against an empty row list — browsing a stubbed page with the
        // search field untouched — is "nothing to search", not "nothing
        // found", and must not draw the same "no settings match" message.
        empty: needle !== "" && matchedIds.length === 0
    };
}
