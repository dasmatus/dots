// How many of a workspace's running toplevels get their own icon before the
// rest collapse into one "+n" badge.
//
// Split out of Workspaces.qml so tests/qml can reach it: resolving an actual
// icon needs DesktopEntries, a Quickshell singleton a `.pragma library`
// script cannot import (it has no import statements of its own) and
// qmltestrunner cannot load anyway. See that file's own header. The cap
// arithmetic underneath it is plain integer math over a count, so it does
// not have to share that fate.
.pragma library

// How many icons a workspace with `total` running toplevels actually draws,
// bounded by `cap` so a workspace with fifteen windows open still fits in
// the bar next to the clock.
function shownCount(total, cap) {
    return Math.min(total, cap);
}

// How many toplevels past the cap get folded into the "+n" badge instead of
// their own icon.
function overflowCount(total, cap) {
    return Math.max(0, total - cap);
}
