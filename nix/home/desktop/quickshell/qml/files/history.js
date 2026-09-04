// Per-tab navigation history, the browser model: a list of visited paths
// and a cursor into it. Going somewhere new from the middle discards
// whatever was ahead, which is what makes Forward mean "the way I came
// back from" rather than "some path I once visited".
//
// Pure, so tests/qml/tst_files_history.qml drives the whole state machine
// with no window. The arithmetic is small and every bug in it is invisible
// until an arrow sends you somewhere you never were.
//
// Returns a new object every time rather than mutating, for the reason
// tabs.js does: QML only re-evaluates a `var` binding when the property is
// reassigned.
.pragma library

function initial(path) {
    return { entries: [path], index: 0 };
}

function currentOf(history) {
    return history.entries[history.index];
}

function canBack(history) {
    return history.index > 0;
}

function canForward(history) {
    return history.index < history.entries.length - 1;
}

// Navigating to where you already are is not a history entry. Without this
// guard, double-clicking the same folder twice would need two Backs to
// leave, and re-listing a directory would too.
function pushed(history, path) {
    if (currentOf(history) === path)
        return history;

    const kept = history.entries.slice(0, history.index + 1);
    kept.push(path);

    return { entries: kept, index: kept.length - 1 };
}

function back(history) {
    if (!canBack(history))
        return history;

    return { entries: history.entries, index: history.index - 1 };
}

function forward(history) {
    if (!canForward(history))
        return history;

    return { entries: history.entries, index: history.index + 1 };
}
