// Pure page arithmetic behind Settings.qml's nav: which dumped field keys
// each real page shows, in what order, and which rows are a dependent
// row's own parent — split out for the same reason search.js is (see its own
// header): Settings.qml reaches PanelWindow, WlrLayershell, IpcHandler and
// Quickshell.Io's Process, all Quickshell types qmltestrunner cannot load
// (tests/README.md), so the one part of "which fields does a page show"
// worth unit-testing at all has to live somewhere that isn't inside it.
.pragma library

// global-settings dump emits one flat array in ITEMS' own table order
// (rust/settings-global/src/menu.rs), which interleaves keys destined for
// different pages — the three AI toggles sit between the git identity rows
// and protonEmail, e.g. A page's own row order is a presentation choice this
// shell owns; dump's order is not a contract for it, so this table is the
// one place that answers "what does this page show, and in what order".
//
// "keyboard" renders keybinds.json directly and owns no dumped field at all;
// "security" (and the wallpaper/displays pages a later task adds) are still
// stubs. Neither gets an entry here — fieldsForPage() below already answers
// "nothing" for any pageId this table does not name.
const PAGE_FIELDS = {
    identity: ["gitName", "gitEmail", "hostname", "timezone", "desktop", "gitSigningKey"],
    wm: ["wmGapsIn", "wmGapsOut", "wmBorderSize", "wmFollowMouse", "wmAnimations", "wmLayout"],
    ai: ["aiOllama", "aiClaude", "aiCodex", "aiOllamaEndpoint", "aiOllamaDefaultModel"],
    accounts: ["protonEmail"]
};

// A dependent row's parent key, keyed by the dependent row's OWN key — the
// data-dep relationship SettingsRow.qml's dependent/dependsOn properties
// need. Kept beside PAGE_FIELDS since both describe the AI page's shape: the
// Ollama endpoint and default-model rows only mean something while aiOllama
// itself is on.
const DEPENDS_ON = {
    aiOllamaEndpoint: "aiOllama",
    aiOllamaDefaultModel: "aiOllama"
};

// `fields` (global-settings dump's array) reordered and filtered down to one
// page's own key list. A key PAGE_FIELDS names that dump did not actually
// carry — a stale binary, or a typo in this table — is left out rather than
// producing a hole in the returned array a Repeater would render as an
// undefined row.
function fieldsForPage(fields, pageId) {
    const keys = PAGE_FIELDS[pageId];
    if (!keys)
        return [];

    const byKey = new Map(fields.map(f => [f.key, f]));
    return keys.map(k => byKey.get(k)).filter(f => f !== undefined);
}

// null for a row with no parent — SettingsRow's own dependsOn already
// defaults to enabled for exactly that case, so a caller reads this straight
// into `dependent`/`dependsOn` with no second branch for "not dependent at
// all".
function dependencyKeyFor(key) {
    return DEPENDS_ON[key] ?? null;
}
