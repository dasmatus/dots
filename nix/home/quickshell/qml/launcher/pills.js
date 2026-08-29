// Pure logic for the launcher's filter pill bar, restoring the contract
// rust/beamenu/src/item.rs documented on `Item::provider`: "every provider
// owns exactly one pill that filters to its own rows." Kept out of
// Launcher.qml so tests/qml/tst_pills.qml can drive it with plain row arrays
// and no PanelWindow, MouseArea or live query anywhere near the test.
.pragma library

// Display label for a provider id. Anything not listed falls back to a
// capitalised copy of the id itself, so a provider added later still gets a
// readable pill instead of a blank one.
const LABELS = {
    apps: "Apps",
    system: "System",
    quicklinks: "Quicklinks",
    snippets: "Snippets",
    files: "Files",
    status: "Status",
    windows: "Windows",
    clipboard: "Clipboard",
    emoji: "Emoji",
    websearch: "Web",
    calc: "Calc"
};

function labelFor(id) {
    if (id in LABELS)
        return LABELS[id];

    return id.length === 0 ? id : id[0].toUpperCase() + id.slice(1);
}

// One pill per provider that produced at least one row in `rows`, ordered by
// each provider's first appearance. That is the order the ambient query
// already concatenates providers in (Launcher.qml's own `results`), so the
// pill bar reads left-to-right the same way every time instead of reordering
// itself as scores change between keystrokes.
function pillsFor(rows) {
    const order = [];
    const counts = {};

    for (const row of rows) {
        const id = row.provider;
        if (!(id in counts)) {
            order.push(id);
            counts[id] = 0;
        }
        counts[id] += 1;
    }

    return order.map(id => ({ id: id, label: labelFor(id), count: counts[id] }));
}

// `pillId === ""` is the pill bar's own "All" state, not a provider nothing
// ever produces — so a caller with no selection does not need a sentinel row
// object to mean "everything".
function filterByPill(rows, pillId) {
    if (pillId === "")
        return rows;

    return rows.filter(row => row.provider === pillId);
}
