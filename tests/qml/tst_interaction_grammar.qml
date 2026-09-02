// Pins the one interaction grammar Arrange, Picker, Cheatsheet and Settings
// are supposed to share: arrows AND j/k move, on every one of the four
// windows. Motivating bug: Settings shipped with only arrows and a comment
// claiming a focused text field would steal j/k as literal characters — the
// opposite of what Arrange.qml (which has five real text fields of its own)
// both claims and relies on. Nothing here proves the claim in a live Qt
// event loop (no compositor in this environment), but the C++ source of
// QQuickTextInput settles it: unmatched keys fall through to
// QQuickTextInputPrivate::processKeyEvent, which inserts the character and
// calls event->accept() before the event ever reaches a parent's
// Keys.onPressed.
//
// qmltestrunner cannot instantiate any of these four windows — every one
// reaches Quickshell.Io — so this reads the shipped QML source as text
// instead, the same XHR idiom tst_tint_wiring.qml and
// tst_chrome_geometry.qml use.
import QtQuick
import QtTest

TestCase {
    name: "InteractionGrammar"

    function readSource(relPath) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl(relPath), false);
        xhr.send();
        compare(xhr.status, 200, relPath + " must be readable (needs QML_XHR_ALLOW_FILE_READ=1)");
        return xhr.responseText;
    }

    // Brace-matched rather than a fixed-width slice, since Picker's handler
    // is a switch statement and the other three are plain if/else chains —
    // this returns exactly the handler's own body regardless of shape.
    function keysOnPressedBody(src) {
        const marker = "Keys.onPressed: event => {";
        const start = src.indexOf(marker);
        verify(start !== -1, "must define a Keys.onPressed handler");

        let depth = 1;
        let i = start + marker.length;
        while (depth > 0 && i < src.length) {
            if (src[i] === "{")
                depth++;
            else if (src[i] === "}")
                depth--;
            i++;
        }
        return src.slice(start, i);
    }

    function test_every_surface_aliases_jk_data() {
        return [
            {
                tag: "Arrange",
                path: "../../nix/home/quickshell/qml/monitors/Arrange.qml",
                down: "root.moveSelection(1)",
                up: "root.moveSelection(-1)"
            },
            {
                tag: "Picker",
                path: "../../nix/home/quickshell/qml/wallpaper/Picker.qml",
                down: "root.moveCursor(root.columnsPerRow())",
                up: "root.moveCursor(-root.columnsPerRow())"
            },
            {
                tag: "Cheatsheet",
                path: "../../nix/home/quickshell/qml/cheatsheet/Cheatsheet.qml",
                down: "root.scrollBy(root.scrollStep)",
                up: "root.scrollBy(-root.scrollStep)"
            },
            {
                tag: "Settings",
                path: "../../nix/home/quickshell/qml/settings/Settings.qml",
                down: "root.moveSelection(1)",
                up: "root.moveSelection(-1)"
            }
        ];
    }

    function test_every_surface_aliases_jk(row) {
        const src = readSource(row.path);
        const body = keysOnPressedBody(src);

        verify(body.indexOf("Qt.Key_J") !== -1, row.tag + "'s Keys.onPressed must handle Key_J");
        verify(body.indexOf("Qt.Key_K") !== -1, row.tag + "'s Keys.onPressed must handle Key_K");
        verify(body.indexOf(row.down) !== -1, row.tag + "'s j must call " + row.down);
        verify(body.indexOf(row.up) !== -1, row.tag + "'s k must call " + row.up);
    }

    function test_settings_footer_hint_advertises_jk() {
        const src = readSource("../../nix/home/quickshell/qml/settings/Settings.qml");
        verify(src.indexOf("\"↑↓/jk\"") !== -1, "Settings' footer hint must advertise the jk alias like the other three surfaces");
    }

    // The false justification this branch shipped: "this surface has real
    // text fields, and a 'j' typed into one ... must land in the field, not
    // get stolen as a move." Arrange has five real text fields and the
    // working j/k alias at once, so the claim never held.
    function test_settings_no_longer_claims_jk_is_unsafe() {
        const src = readSource("../../nix/home/quickshell/qml/settings/Settings.qml");
        verify(src.indexOf("Arrows only") === -1, "the false 'arrows only, real text fields' justification must be removed");
    }
}
