// String dissection of desktop entries for the launcher's app provider —
// split out from rank.js because this is text parsing over Exec= lines and
// building storage-key strings, not score arithmetic, and the two files
// need entirely different fixtures to test: real captured .desktop Exec
// lines here, synthetic score/timestamp records there. Kept out of
// Providers.qml so tests/qml/tst_apps.qml can drive it with plain strings
// and no DesktopEntry, FileView or Quickshell.Io anywhere near the test.
.pragma library

// Whether a launched .desktop entry is a Brave-hosted PWA rather than an
// ordinary application, decided from its own Exec= line. Brave writes one
// desktop file per installed PWA
// (~/.local/share/applications/brave-<32 hex chars>-Default.desktop) with
// its own --app-id=<id> flag baked into Exec — that flag, not the filename,
// is the discriminator, because the filename's "brave-" prefix is
// ambiguous against Brave the browser itself: brave-browser.desktop's own
// Exec launches with no --app-id at all, so a filename match would have to
// separately special-case it or misclassify it as a PWA. Anchored on a word
// boundary (start of string or preceding whitespace) so this cannot fire on
// some other flag that merely ends in "--app-id=", and left unanchored at
// the end so the profile/id text following the flag never has to be parsed
// just to answer this question.
//
// RegExp.test coerces its argument to a string rather than throwing, so
// this is already total over undefined and "" — the two shapes a missing
// or empty Exec= line actually produces.
function isWebApp(execString) {
    return /(^|\s)--app-id=/.test(execString);
}

// rank.js's records are a flat namespace shared across every provider that
// opts into frecency, so every key here is prefixed by provider — "apps:"
// marks an application row's own usage history apart from some future
// provider's "quicklinks:" or "snippets:" key landing on the same id by
// coincidence.
function appKey(id) {
    return "apps:" + id;
}

// A desktop action (Providers.qml's per-app drill-in row, e.g. Mastodon's
// "Compose new post") earns its own frecency history apart from launching
// the app plain, keyed on the app's id plus the action's own id. Built on
// DesktopAction.id specifically, never .name: id is a plain, constant
// QString (quickshell-core.qmltypes:200, isPropertyConstant: true) drawn
// from the desktop entry's own [Desktop Action <id>] section header, while
// name is bindable and notifies a change (:201-210) because it is the
// localised, user-visible label — keying frecency on it would silently
// reset a user's usage history for every action on every locale switch.
function actionKey(id, actionId) {
    return "apps:" + id + ":action:" + actionId;
}
