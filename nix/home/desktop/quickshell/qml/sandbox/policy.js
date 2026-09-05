// Pure logic behind the sandbox surfaces: the Security & privacy settings
// page's dashboard/permissions rendering (settings/pages/security.qml) and
// the live permission prompt (sandbox/Prompt.qml). Both reach Quickshell.Io
// types (Process, FileView) qmltestrunner cannot instantiate — see
// tests/README.md — so everything worth a unit test on its own lives here
// instead, the same split bar/battery.js makes for Battery.qml.
//
// The permissions section reads `dots-sandbox catalog --json`, not
// `policy dump`: `capabilityGroups`/`appsForCapability`/`unconfinedEntries`
// below are what turned the old per-app listing (`appEntries`, now gone)
// into the Android-style permission-manager shape the task brief asked
// for — capability first, apps second.
//
// Shared rather than one copy per component (services/devices.js is already
// imported from both files/Sidebar.qml and launcher/Providers.qml this same
// way): the overrides-file merge is the exact same operation whichever
// surface is doing the writing, and two copies of "how do I edit
// overrides.json" is exactly the kind of drift a single shared module
// exists to prevent.
.pragma library

// rust/dots-sandbox/src/report.rs's `Status` enum, translated to a colour
// NAME rather than a real colour — a `.pragma library` has no import of its
// own to reach Theme with, the same reason battery.js hands back
// "red"/"yellow"/"green" strings for Battery.qml to map itself.
//
// "unavailable" resolves to "dim", never "red": report.rs's own module doc
// comment exists specifically so kernel lockdown being absent (not compiled
// into this kernel) is never confused with kernel lockdown being off, and a
// dashboard that painted both the same colour would erase that distinction
// the instant it reached the screen. tests/qml/tst_sandbox_policy.qml pins
// `toneFor("unavailable") !== toneFor("fail")` directly so a future refactor
// that collapses the switch back into "anything not ok is red" fails loudly.
function toneFor(status) {
    switch (status) {
    case "ok":
        return "green";
    case "warn":
        return "yellow";
    case "fail":
        return "red";
    case "unavailable":
        return "dim";
    default:
        // A status name this module has never seen (a newer collector, an
        // older page) is exactly as unconfirmed as a card that says so
        // itself — "dim" again, not a guessed colour.
        return "dim";
    }
}

// The word a status Pill actually shows. A plain `status.toUpperCase()`
// would print "UNAVAILABLE" exactly as loud as "FAIL", which undoes the
// point of toneFor's own split — a sentence-case label is the other half of
// keeping the two from reading as the same thing at a glance.
function statusLabel(status) {
    switch (status) {
    case "ok":
        return "OK";
    case "warn":
        return "Warning";
    case "fail":
        return "Failing";
    case "unavailable":
        return "Unavailable";
    default:
        return status;
    }
}

// The capability vocabulary comes from `catalog --json`'s own
// `capabilities` array, built by `catalog.rs`'s `capability_vocabulary()`
// from `policy.rs`'s `Capability::ALL`. It is deliberately NOT restated
// here.
//
// A label table in this file was the first version, and it is the exact
// second-source-of-truth problem the ledger flagged: adding or renaming a
// capability in `policy.rs` left this list stale, the page then showed an
// old name or silently omitted the capability altogether, and nothing
// anywhere failed to say so. Reading the vocabulary the binary emits means
// a new capability appears here the moment it exists, with no edit.
//
// An absent array yields an empty list rather than a hardcoded fallback:
// falling back would reintroduce the same drift under a different name,
// and this page's whole stance is that it would rather show nothing than
// show something it cannot source.
function capabilityVocabulary(catalogSet) {
    if (!catalogSet || !Array.isArray(catalogSet.capabilities))
        return [];

    return catalogSet.capabilities;
}

// `dots-sandbox catalog --json`'s `apps` array, defensively normalized: an
// absent or malformed array is "nothing to show" rather than a thrown
// error — the same treatment `appEntries` gave `policy dump`'s object
// before it. Every function below reaches through this rather than
// repeating the same `Array.isArray` guard, since the permissions section
// now reads the catalog once per group AND once per drill-in.
function catalogApps(catalogSet) {
    if (!catalogSet || !Array.isArray(catalogSet.apps))
        return [];

    return catalogSet.apps;
}

// `catalog --json`'s `CatalogEntry` carries no `kind`/`unconfined` tag of
// its own (unlike `policy dump`'s `ResolvedApp`, which this page used to
// read directly) — an unconfined app instead surfaces as the one shape
// `rust/dots-sandbox/src/catalog.rs`'s `entry_from_policy_only` produces
// for `ResolvedApp::Unconfined`: no tier, no declared capabilities. Both
// must agree, not just `tier`, because a policy-only entry for a
// SANDBOXED app that simply has zero declared capabilities is a real,
// different case (`entry_from_policy_only`'s `Sandboxed` arm always
// carries `Some(tier)`, so a null tier alone already only happens on the
// unconfined path — checking `caps` too costs nothing and keeps this from
// leaning on that alone).
function isUnconfined(app) {
    return !app.tier && (!Array.isArray(app.caps) || app.caps.length === 0);
}

// The top-level list the permissions section now walks: one entry per
// capability `policy.rs` knows about, in its own declared order, each
// carrying how many catalog apps actually DECLARED it — never how many
// currently have it allowed, which is a different question the drill-in
// view answers per app instead. An unconfined app contributes to no
// count: it has no capability list of its own to have requested one (see
// `policy.rs`'s `ResolvedApp::Unconfined`, which carries a reason and
// nothing else).
function capabilityGroups(catalogSet) {
    const apps = catalogApps(catalogSet);
    return capabilityVocabulary(catalogSet).map(cap => ({
        name: cap.name,
        label: cap.label,
        description: cap.description ?? "",
        count: apps.filter(app => !isUnconfined(app) && Array.isArray(app.caps) && app.caps.includes(cap.name)).length
    }));
}

// One capability drilled into: every app that declared it, each carrying
// its OWN resolved state for exactly this capability, never the app's
// other ones — the drill-in view has no reason to reach for them. `state`
// defaults to "ask", never "allow" or "deny", when the catalog's own
// resolved map is silent about this pair: a hole in the resolved state is
// a place to prompt, not a place to guess permissive or guess revoked.
// Sorted by name rather than appId, since the drill-in list is what a
// human actually reads.
function appsForCapability(catalogSet, capability) {
    return catalogApps(catalogSet)
        .filter(app => !isUnconfined(app) && Array.isArray(app.caps) && app.caps.includes(capability))
        .map(app => ({
            appId: app.appId,
            name: app.name || app.appId,
            icon: app.icon || "",
            state: (app.state && app.state[capability]) || "ask"
        }))
        .sort((a, b) => a.name.localeCompare(b.name));
}

// Apps the policy exempts outright — shown once, unconditionally, at the
// permissions section's own top level rather than behind any one
// capability's drill-in, since an unconfined app has no capability list
// to be filed under. Never hidden: an invisible exemption list is how a
// permissions UI starts lying about what it controls, the same reasoning
// the old `appEntries`-driven rendering already carried.
//
// `reason` is `CatalogEntry.reason` (rust/dots-sandbox/src/catalog.rs),
// carried from `ResolvedApp::Unconfined`'s own string, so this row can say
// WHY an app is exempt rather than only that it is. That difference is the
// whole point of showing the list: "Unsandboxed" alone reads as an
// oversight, while "the secret broker other things connect to" reads as
// the deliberate decision it was.
//
// Still read defensively (`|| ""`), because `reason` is omitted from the
// JSON entirely for a sandboxed app and an older binary emits no such
// field at all. An empty reason is the honest degrade; a fabricated one
// would not be.
function unconfinedEntries(catalogSet) {
    return catalogApps(catalogSet)
        .filter(isUnconfined)
        .map(app => ({
            appId: app.appId,
            name: app.name || app.appId,
            icon: app.icon || "",
            reason: app.reason || ""
        }))
        .sort((a, b) => a.name.localeCompare(b.name));
}

// Whether toggling one capability can ever apply to an already-running
// instance of the app, or only to its next launch.
//
// Always `false` today: rust/dots-sandbox/src/argv.rs turns every one of
// these seven into either a network-namespace flag (`net`) or a plain
// `--bind`/`--bind-ro` mount, and both are spawn-time-only — nspawn/vmspawn
// take no flag for changing either on a machine that already exists, and
// `machinectl`'s own verbs are asymmetric (`bind` has no matching `unbind`;
// only `bind-volume`/`unbind-volume` form a reversible pair, per
// rust/dots-sandbox/src/grants.rs's own module doc comment) — a plain bind
// can never be revoked live regardless of which capability it came from,
// and the static catalog never produces a volume-backed grant for this
// function to say "yes" about.
//
// A function rather than a hardcoded page string on purpose: the day one of
// these seven moves onto a volume-backed grant (or a new capability is added
// that does), this is the one place that answers differently, not a
// sentence to go find and edit in QML.
function needsRelaunch(_capability) {
    return true;
}

// Replaces one app's one capability inside `existingRoot` (the overrides
// file's already-parsed shape: `{version, apps, denyPaths}`) and returns a
// NEW root object rather than mutating in place — the caller hands this
// straight to `overridesFile.setText(JSON.stringify(...))`, and QML never
// notices an in-place mutation of a property it already read (Settings.qml's
// own `edit()` makes the identical point about `root.edits`).
//
// Every app and every OTHER capability `existingRoot` already carries
// survives untouched; only the one named pair changes. A brand-new app entry
// is created bare (no `unconfined`/`tier` of its own) when overrides.json has
// never mentioned this app before: rust/dots-sandbox/src/policy.rs's merge
// only ever reads `tier`/`unconfined` from whichever layer sets them,
// falling back to the defaults layer's own when the override is silent, so
// an override entry that speaks to only one capability is exactly the
// "narrow, not replace" shape its merge rules already expect.
function withCapabilityOverride(existingRoot, appId, capability, state) {
    const version = existingRoot.version || 1;
    const apps = Object.assign({}, existingRoot.apps);
    const existingApp = apps[appId] || {};
    const caps = Object.assign({}, existingApp.caps, { [capability]: state });
    apps[appId] = Object.assign({}, existingApp, { caps: caps });

    return {
        version: version,
        apps: apps,
        denyPaths: (existingRoot.denyPaths || []).slice()
    };
}
