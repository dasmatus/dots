// Pins the one interaction grammar Arrange, Picker, Cheatsheet and Settings
// are supposed to share: arrows AND j/k move, in the same direction, on every
// one of the four windows. Motivating bug: Settings shipped with only arrows
// and a comment claiming a focused text field would steal j/k as literal
// characters — the opposite of what Arrange.qml (which has five real text
// fields of its own) both claims and relies on.
//
// That claim is not taken on faith here or in the shipped comments:
// tst_focus_grammar.qml drives real key events at both field shapes and
// checks which handler sees them. This file covers the other half, that each
// surface declares the alias at all, and reads the shipped QML as text to do
// it — qmltestrunner cannot instantiate any of these four windows, every one
// reaches Quickshell.Io (tests/README.md), the same XHR idiom
// tst_tint_wiring.qml and tst_chrome_geometry.qml use.
//
// Assertions run against comment-stripped source, so prose naming a key or a
// move function cannot stand in for a handler that calls neither. The one
// exception is marked where it occurs: an assertion that a comment is *gone*
// has to read the raw file, or stripping would satisfy it unconditionally.
import QtQuick
import QtTest
import "sourcescan.js" as SourceScan

TestCase {
    name: "InteractionGrammar"

    function readSource(relPath) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl(relPath), false);
        xhr.send();
        compare(xhr.status, 200, relPath + " must be readable (needs QML_XHR_ALLOW_FILE_READ=1)");
        return xhr.responseText;
    }

    function readCode(relPath) {
        return SourceScan.stripComments(readSource(relPath));
    }

    // Brace-matched rather than a fixed-width slice, since Picker's handler is
    // a switch statement and the other three are plain if/else chains — this
    // returns exactly the handler's own body regardless of shape.
    function keysOnPressedBody(src) {
        return SourceScan.blockAfter(src, "Keys.onPressed: event => {");
    }

    // The slice of a handler body belonging to one key: from that key's own
    // Qt.Key_ reference up to whichever Qt.Key_ comes next. Bounding on "the
    // next key branch" rather than on the paired key is what lets this read
    // Picker's switch, where six unrelated cases (h/l/m/o/c/r) sit between
    // Key_K and the end, as well as the three if/else chains.
    //
    // Comparing branches, not the whole body, is the point: a body that
    // mentions Key_J, Key_K and both move calls somewhere satisfies any
    // presence check even when the two are wired backwards.
    function branchFor(body, key) {
        const start = body.indexOf(key);
        if (start === -1)
            return "";

        const rest = body.slice(start + key.length).search(/Qt\.Key_/);
        return rest === -1 ? body.slice(start) : body.slice(start, start + key.length + rest);
    }

    function test_every_surface_aliases_jk_data() {
        return [
            {
                tag: "Arrange",
                path: "../../nix/home/desktop/quickshell/qml/monitors/Arrange.qml",
                down: "root.moveSelection(1)",
                up: "root.moveSelection(-1)"
            },
            {
                tag: "Picker",
                path: "../../nix/home/desktop/quickshell/qml/wallpaper/Picker.qml",
                down: "root.moveCursor(root.columnsPerRow())",
                up: "root.moveCursor(-root.columnsPerRow())"
            },
            {
                tag: "Cheatsheet",
                path: "../../nix/home/desktop/quickshell/qml/cheatsheet/Cheatsheet.qml",
                down: "root.scrollBy(root.scrollStep)",
                up: "root.scrollBy(-root.scrollStep)"
            },
            {
                tag: "Settings",
                path: "../../nix/home/desktop/quickshell/qml/settings/Settings.qml",
                down: "root.moveSelection(1)",
                up: "root.moveSelection(-1)"
            }
        ];
    }

    // j moves forward and k moves back — the direction, not just the presence
    // of both letters. Swapping the two inverts every one of these surfaces
    // while leaving a presence-only check green, which is how the first
    // version of this test shipped.
    function test_every_surface_aliases_jk(row) {
        const body = keysOnPressedBody(readCode(row.path));
        verify(body !== "", row.tag + " must define a Keys.onPressed handler");

        const jBranch = branchFor(body, "Qt.Key_J");
        const kBranch = branchFor(body, "Qt.Key_K");
        verify(jBranch !== "", row.tag + "'s Keys.onPressed must handle Key_J");
        verify(kBranch !== "", row.tag + "'s Keys.onPressed must handle Key_K");

        verify(jBranch.indexOf(row.down) !== -1, row.tag + "'s j must move forward, by calling " + row.down);
        verify(jBranch.indexOf(row.up) === -1, row.tag + "'s j must not move back — its branch calls " + row.up);
        verify(kBranch.indexOf(row.up) !== -1, row.tag + "'s k must move back, by calling " + row.up);
        verify(kBranch.indexOf(row.down) === -1, row.tag + "'s k must not move forward — its branch calls " + row.down);
    }

    // Arrows are the half that keeps working while a text field holds focus
    // (tst_focus_grammar.qml), so every surface has to keep them too — an
    // alias that replaced the arrows rather than joining them would leave a
    // focused field with no way to move at all.
    function test_every_surface_keeps_the_arrow_handlers(row) {
        const src = readCode(row.path);
        verify(src.indexOf("Keys.onUpPressed") !== -1, row.tag + " must keep its Up arrow handler");
        verify(src.indexOf("Keys.onDownPressed") !== -1, row.tag + " must keep its Down arrow handler");
    }

    function test_every_surface_keeps_the_arrow_handlers_data() {
        return test_every_surface_aliases_jk_data();
    }

    function test_settings_footer_hint_advertises_jk() {
        const src = readCode("../../nix/home/desktop/quickshell/qml/settings/Settings.qml");
        verify(src.indexOf("\"↑↓/jk\"") !== -1, "Settings' footer hint must advertise the jk alias like the other three surfaces");
    }

    // Reads the RAW file, not readCode: this asserts a comment is gone, and
    // comment-stripped source satisfies it no matter what the file says.
    //
    // The false justification this replaced: "this surface has real text
    // fields, and a 'j' typed into one ... must land in the field, not get
    // stolen as a move." Arrange has five real text fields and the working
    // j/k alias at once, so the claim never held.
    function test_settings_no_longer_claims_jk_is_unsafe() {
        const src = readSource("../../nix/home/desktop/quickshell/qml/settings/Settings.qml");
        verify(src.indexOf("Arrows only") === -1, "the false 'arrows only, real text fields' justification must be removed");
    }
}
