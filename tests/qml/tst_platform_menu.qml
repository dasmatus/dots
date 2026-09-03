// Pins the one thing that makes a tray right click do anything at all: the
// platform-menu path and the pragma that enables it have to ship together.
//
// Motivating bug: Tray.qml's right-click branch called
// `modelData.display(QsWindow.window, ...)` — the correct call — while
// shell.qml carried no `//@ pragma UseQApplication`. Quickshell builds a
// QGuiApplication without it, Qt's platform-menu layer never initialises,
// and every display() aborted into the log with "Cannot display
// PlatformMenuEntry as quickshell was not started in QApplication mode."
// Nothing drew, nothing threw, and the bar looked healthy. The same pragma
// gates QsMenuAnchor.open(), so reaching for that newer API instead of
// display() would not have escaped it.
//
// The assertion has to read RAW source, and that is the whole subtlety here:
// `//@ pragma` is a comment, so the comment strip every other source-text
// test in this directory runs first would delete the very line being looked
// for and leave the check passing on a file that had lost it. tests/README.md
// and tst_interaction_grammar.qml both name this trap; this is the second
// place it bites, so test_pragma_is_comment_shaped below pins the reason
// rather than leaving the raw read looking like an oversight.
//
// The rule is conditional on purpose. Rendering the menu in QML over
// QsMenuOpener instead would need no QApplication, and then the pragma should
// go — so it is required only while a caller still uses the platform path.
// Drop both together, and the data function below is where that shows up.
import QtQuick
import QtTest
import "sourcescan.js" as SourceScan

TestCase {
    name: "PlatformMenu"

    readonly property string shellPath: "../../nix/home/quickshell/qml/shell.qml"
    readonly property string pragmaLine: "//@ pragma UseQApplication"

    // The shipped QML reaches Quickshell.Io and a compositor, neither of which
    // qmltestrunner can give it (tests/README.md), so these read the files as
    // text — the same XHR idiom tst_interaction_grammar.qml uses.
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

    // Every shipped file that reaches Qt's platform-menu layer, with the call
    // that puts it there. Listed rather than globbed because QML has no
    // directory read: a new caller is a line here, and the last one leaving is
    // what releases shell.qml from the pragma.
    function test_platform_menu_callers_data() {
        return [
            {
                tag: "Tray right click",
                path: "../../nix/home/quickshell/qml/bar/Tray.qml",
                call: ".display("
            }
        ];
    }

    // Read stripped, so a comment describing the call cannot stand in for the
    // call itself and hold the pragma requirement up on its own.
    function test_platform_menu_callers(row) {
        verify(readCode(row.path).indexOf(row.call) !== -1,
               row.tag + ": " + row.path + " must still make the " + row.call
               + " call this file requires the pragma for — if it no longer does, "
               + "drop its row here and drop the pragma from shell.qml with it");
    }

    // The pragma itself. Raw, per this file's header.
    function test_root_carries_pragma() {
        verify(readSource(shellPath).indexOf(pragmaLine) !== -1,
               "shell.qml must carry " + pragmaLine
               + " — without it every display() and QsMenuAnchor.open() in the shell "
               + "aborts into the log and no tray menu ever opens");
    }

    // Quickshell reads its `//@` pragmas out of the file header, ahead of the
    // QML body: one placed after the first import is read by nothing.
    function test_pragma_precedes_the_imports() {
        const src = readSource(shellPath);
        const firstImport = src.indexOf("\nimport ");
        const at = src.indexOf(pragmaLine);
        verify(firstImport !== -1, "shell.qml must have imports for this to mean anything");
        // `at !== -1` first, and not for tidiness: a missing pragma indexes to
        // -1, which is below every offset in the file, so ordering alone would
        // pass this on the exact file it exists to reject.
        verify(at !== -1 && at < firstImport,
               pragmaLine + " must sit above shell.qml's first import, where Quickshell looks for it");
    }

    // Why test_root_carries_pragma reads raw. If the strip ever stopped eating
    // this line the raw read would look like an arbitrary choice, and the next
    // person would tidy it into readCode and get a check that passes on a
    // shell.qml the pragma has been deleted from.
    function test_pragma_is_comment_shaped() {
        compare(readCode(shellPath).indexOf(pragmaLine), -1,
                "the pragma is a comment and the strip must eat it — "
                + "which is exactly why the assertion above reads raw source");
    }
}
