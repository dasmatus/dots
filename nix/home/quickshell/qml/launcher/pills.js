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
    devices: "Devices",
    status: "Status",
    windows: "Windows",
    clipboard: "Clipboard",
    emoji: "Emoji",
    websearch: "Web",
    calc: "Calc"
};

// Every row pillsFor sees is supposed to carry a `provider` string — every
// provider function in Providers.qml sets one — but that is a convention,
// not something the type system enforces, and one row built without it must
// not be able to throw pillsFor's caller into `undefined`. Rows failing that
// convention are grouped under this id instead of by whatever they are
// missing, so the anomaly surfaces as one visible "Other" pill rather than
// vanishing into "All" unremarked or taking the whole bar down with it.
const FALLBACK_PROVIDER = "other";
LABELS[FALLBACK_PROVIDER] = "Other";

function providerOf(row) {
    return typeof row.provider === "string" && row.provider.length > 0 ? row.provider : FALLBACK_PROVIDER;
}

function labelFor(id) {
    if (typeof id !== "string" || id.length === 0)
        return LABELS[FALLBACK_PROVIDER];

    return id in LABELS ? LABELS[id] : id[0].toUpperCase() + id.slice(1);
}

// One pill per provider, ordered by first appearance in `order` — the
// ambient query's own registry-order concatenation (Launcher.qml's
// `ambientRows`) — so the bar's left-to-right order stays put across a
// keystroke instead of reordering as match scores change.
//
// Counts, deliberately, come from `counted` instead: whatever list the
// caller's own filter actually runs against (Launcher.qml's
// `unfilteredResults`, the sorted-and-capped display list). `order` is
// untruncated and unsorted, so counting from it would print a number a
// click could not back up — the exact bug this replaced, where a provider
// pushed past the display cap still advertised its full row count while
// filtering into it returned fewer rows, or none. A provider absent from
// `counted` entirely is dropped rather than shown at a count of zero: a
// pill that cannot deliver a single row is not a filter, it is a dead end
// with a number on it.
function pillsFor(order, counted) {
    const sequence = [];
    const counts = {};

    for (const row of order) {
        const id = providerOf(row);
        if (!(id in counts)) {
            sequence.push(id);
            counts[id] = 0;
        }
    }

    for (const row of counted) {
        const id = providerOf(row);
        if (id in counts)
            counts[id] += 1;
    }

    return sequence.filter(id => counts[id] > 0).map(id => ({ id: id, label: labelFor(id), count: counts[id] }));
}

// `pillId === ""` is the pill bar's own "All" state, not a provider nothing
// ever produces — so a caller with no selection does not need a sentinel row
// object to mean "everything".
//
// Compares against `providerOf(row)`, not `row.provider` directly, so this
// agrees with the grouping `pillsFor` used to build the "Other" pill in the
// first place. A providerless row normalises to `FALLBACK_PROVIDER` there;
// comparing the raw (`undefined`) field here would make "Other" a pill that
// advertises a count and delivers zero rows for it — a promise `pillsFor`'s
// own contract exists to rule out.
function filterByPill(rows, pillId) {
    if (pillId === "")
        return rows;

    return rows.filter(row => providerOf(row) === pillId);
}
