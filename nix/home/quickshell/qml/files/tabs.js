// Tab state for Files.qml, kept pure so tests/qml/tst_files_tabs.qml can
// drive open/close/label with no window anywhere near it.
//
// A tab is one directory. It used to be a two-pane layout, which is what a
// Neovim tabpage is, but the second pane went away with the Norton
// Commander view and a tab holding one path is what is left.
//
// Every function returns a new array rather than mutating: QML only
// re-evaluates a `var` binding when the property is reassigned, so a
// push() into the existing array updates nothing on screen.
.pragma library

.import "history.js" as History

function newTab(path) {
    return { path: path, history: History.initial(path) };
}

function opened(tabs, path) {
    return tabs.concat([newTab(path)]);
}

// Closing the last tab leaves it in place. A file manager with no tab has
// nothing to draw and no way back, so the floor is one rather than an
// empty window the user has to reopen.
function closed(tabs, index) {
    if (tabs.length <= 1)
        return tabs.slice();

    return tabs.slice(0, index).concat(tabs.slice(index + 1));
}

// Where the selection lands after a close: the tab to the left, except
// when the first was closed, which has nothing to its left.
function indexAfterClose(tabs, index, activeIndex) {
    if (tabs.length <= 1)
        return 0;

    if (activeIndex > index || activeIndex === tabs.length - 1)
        return Math.max(0, activeIndex - 1);

    return activeIndex;
}

function clampIndex(index, length) {
    if (length <= 0)
        return 0;

    return Math.max(0, Math.min(index, length - 1));
}

// The basename, since a tab has room for one path component and the full
// path already sits in the pane header below it. Root has no basename to
// take, so it keeps its slash.
function labelFor(tab) {
    if (tab.path === "/")
        return "/";

    const trimmed = tab.path.replace(/\/$/, "");
    const cut = trimmed.lastIndexOf("/");
    return cut < 0 ? trimmed : trimmed.slice(cut + 1);
}
