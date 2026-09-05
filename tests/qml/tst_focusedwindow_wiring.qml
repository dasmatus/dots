// FocusedWindow.qml's wiring into focusedwindow.js and into Pill — the same
// reachability gap tst_pill_wiring.qml's own header names. Pure unit tests
// on the extracted arithmetic (tst_focusedwindow.qml) prove
// availableTitleWidth() is correct in isolation, not that the component
// actually calls it with the right arguments in the right order, and not
// that the safety-critical hiding behaviour sits on the right item.
// Swapping Theme.barPillPadding and Theme.barIconSize at the call site
// would still type-check (both are `int`) and pass every arithmetic test,
// since those feed the function real numbers directly rather than through
// this binding — exactly the gap tst_pill_wiring.qml's own round 1 bug fell
// through, where pillsFor/filterByPill were correct while Launcher.qml
// called them wrong and no unit test could see it.
//
// qmltestrunner cannot instantiate FocusedWindow.qml itself: it calls
// Quickshell.iconPath, reads DesktopEntries and reaches into a Hyprland
// monitor object, none of which exist under qmltestrunner (see
// focusedwindow.js's own header and tests/README.md) — so this reads the
// shipped source as text instead, the same XHR idiom tst_pill_wiring.qml
// and tst_monitor_parity.qml use.
import QtQuick
import QtTest
import "sourcescan.js" as Scan

TestCase {
    name: "FocusedWindowWiring"

    function focusedWindowSource() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../nix/home/desktop/quickshell/qml/bar/FocusedWindow.qml"), false);
        xhr.send();
        compare(xhr.status, 200, "FocusedWindow.qml must be readable (needs QML_XHR_ALLOW_FILE_READ=1)");
        return Scan.stripComments(xhr.responseText);
    }

    // Pins the exact four-argument call, in order: cap, padding, iconSize,
    // hasIcon. A swap of Theme.barPillPadding and Theme.barIconSize is the
    // motivating regression — both are plain `int` properties, so qmllint
    // cannot tell them apart, and tst_focusedwindow.qml's own cases feed
    // availableTitleWidth() numbers directly rather than through this
    // binding, so they cannot catch a swap here either.
    function test_titleMaxWidth_calls_the_pure_function_with_arguments_in_order() {
        const src = focusedWindowSource();
        verify(src.indexOf("FocusedWindowMath.availableTitleWidth(Theme.barTitleMaxWidth, Theme.barPillPadding, Theme.barIconSize, root.hasIcon)") !== -1, "titleMaxWidth must call availableTitleWidth(cap, padding, iconSize, hasIcon) in that exact order");
    }

    // The brief's single most safety-critical behaviour: an empty capsule
    // floating in the bar's centre is worse than the bare, muted text it
    // replaced, so the whole Pill — not just the title Text inside it — has
    // to hide with no toplevel. Sourcescan cannot parse QML into a tree, so
    // this pins position instead: the visible binding has to fall between
    // where the root Pill opens and where its first child item opens, which
    // is where a property declared directly on `Pill { id: root; ... }`
    // has to sit, and it must not be found inside the Text block at all —
    // the exact regression a binding moved one scope too deep would be.
    function test_visible_is_bound_on_the_pill_root_not_a_child() {
        const src = focusedWindowSource();

        const rootStart = src.indexOf("Pill {");
        verify(rootStart !== -1, "the component must be declared as Pill { id: root; ... }");

        const visibleAt = src.indexOf("visible: root.toplevel !== null");
        verify(visibleAt !== -1, "the Pill must hide with `visible: root.toplevel !== null`");

        const firstChildAt = src.indexOf("Image {");
        verify(firstChildAt !== -1, "the icon Image must exist as the Pill's first child");

        verify(visibleAt > rootStart, "the visible binding must be part of the Pill root's own body");
        verify(visibleAt < firstChildAt, "the visible binding must sit in the Pill root's own property list, before its first child — not inside Image or Text");

        const textBlock = Scan.blockAfter(src, "Text {");
        verify(textBlock !== "", "the title Text block must be found");
        verify(textBlock.indexOf("visible:") === -1, "the title Text must not carry its own visible binding — hiding the whole capsule belongs to the Pill root alone");
    }
}
