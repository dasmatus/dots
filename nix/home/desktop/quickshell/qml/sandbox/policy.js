// Pure logic behind the sandbox surfaces: the Security & privacy settings
// page's dashboard/permissions rendering (settings/pages/security.qml) and
// the live permission prompt (sandbox/Prompt.qml). Both reach Quickshell.Io
// types (Process, FileView) qmltestrunner cannot instantiate — see
// tests/README.md — so everything worth a unit test on its own lives here
// instead, the same split bar/battery.js makes for Battery.qml.
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

// `dots-sandbox policy dump`'s `capabilities` object serializes in
// Capability's declared Rust enum order (net, nix-daemon, repo-read, ...:
// rust/dots-sandbox/src/policy.rs's `Capability::ALL`), not alphabetically —
// a fine order for Rust's own purposes, not a UI contract this page should
// depend on staying stable. Sorted once here rather than trusted wherever
// it's read.
function capabilityEntries(capabilities) {
    if (!capabilities)
        return [];

    return Object.keys(capabilities)
        .sort()
        .map(name => ({ name: name, state: capabilities[name] }));
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

// `dots-sandbox policy dump`'s `apps` object is a Rust `BTreeMap`, which
// already serializes alphabetically — but trusting whatever order
// `JSON.parse` happens to preserve is an implicit contract this file would
// rather not lean on (Arrange.qml's own `overridesRoot` comment makes the
// same call about a V4Sequence for the identical reason). Sorted explicitly,
// once, into the flat array the page's Repeater actually walks.
function appEntries(policySet) {
    if (!policySet || !policySet.apps)
        return [];

    return Object.keys(policySet.apps)
        .sort()
        .map(id => Object.assign({ id: id }, policySet.apps[id]));
}
