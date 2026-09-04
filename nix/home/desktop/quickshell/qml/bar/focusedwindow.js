// Pure arithmetic behind FocusedWindow.qml's title elision.
//
// Split out of the component so tests/qml can reach it: FocusedWindow.qml is
// now a Pill, and Pill inherits Rectangle through a chain that ultimately
// reaches Quickshell's own types, which qmltestrunner cannot instantiate —
// see tests/README.md and battery.js's own header for the same reasoning.
// Everything here is arithmetic over numbers, so the test needs no
// compositor and no palette.
.pragma library

// Pill.qml's own internal Row spacing between its children — 6px, applied
// between the icon and the title whenever the icon is showing. Not a Theme
// token: Pill.qml hardcodes it and exposes no property to read it back, so
// it is repeated here rather than invented as a new palette key.
const PILL_ROW_SPACING = 6;

// How much of Theme.barTitleMaxWidth is left for the title Text once the
// Pill it now lives in has taken its own cut: horizontalPadding on both
// sides, and — only when the icon is actually showing — the icon's own
// width plus the gap ahead of it.
//
// Clamped at zero rather than left to go negative. Theme.barTitleMaxWidth
// bounds the whole capsule, not just the text, so a future edit that shrinks
// it below what the padding and icon alone need must not hand the title's
// `width` binding a negative number — Qt's Text has no defined behaviour for
// that, and FocusedWindow.qml's own bindings still evaluate even while the
// Pill is invisible (no toplevel), so this has to stay well-defined there
// too.
function availableTitleWidth(cap, padding, iconSize, hasIcon) {
    const iconAllowance = hasIcon ? iconSize + PILL_ROW_SPACING : 0;
    return Math.max(0, cap - padding * 2 - iconAllowance);
}
