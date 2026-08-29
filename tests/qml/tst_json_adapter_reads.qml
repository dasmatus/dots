// Reachability tests, tst_tint_wiring.qml's own readSource-plus-indexOf
// idiom: JsonAdapter has no `root` property on this Quickshell build —
// quickshell-io.qmltypes declares it (and its FileViewAdapter prototype)
// with not one property — so any `adapter.root` read is silently always
// undefined. Three unrelated components (the launcher's quicklinks/
// snippets/emoji providers, the cheatsheet's own keybind groups, and
// tree.nix's generated Theme.qml accent) all carried that exact read,
// each masked by its own `?? []`/`?? ({...})` fallback, for as long as
// nothing asserted against the shipped source. None of the three can be
// instantiated live: Providers.qml and Cheatsheet.qml reach Quickshell.Io's
// FileView, and tree.nix is not QML at all — it is the Nix function that
// generates Theme.qml's source text, so this reads that generator's own
// source rather than a built artifact, the same way every other file here
// reads shipped QML rather than something qmltestrunner produced.
import QtQuick
import QtTest

TestCase {
    name: "JsonAdapterReads"

    function readSource(relPath) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl(relPath), false);
        xhr.send();
        compare(xhr.status, 200, relPath + " must be readable (needs QML_XHR_ALLOW_FILE_READ=1)");
        return xhr.responseText;
    }

    function countOccurrences(haystack, needle) {
        return haystack.split(needle).length - 1;
    }

    function test_providers_never_reads_the_nonexistent_adapter_root() {
        const providers = readSource("../../nix/home/quickshell/qml/launcher/Providers.qml");
        verify(providers.indexOf(".adapter.root") === -1, "JsonAdapter has no `root` property on this Quickshell build — reading a bare root off it is silently always undefined");
    }

    // quicklinksFile, snippetsFile and emojiFile each need their OWN
    // declared `items` property — JsonAdapter only populates a property
    // declared on the adapter instance itself, and a shared instance is not
    // an option here since each FileView owns a different JSON file.
    function test_providers_declares_a_property_on_every_adapter() {
        const providers = readSource("../../nix/home/quickshell/qml/launcher/Providers.qml");
        compare(countOccurrences(providers, "property var items"), 3, "quicklinksFile, snippetsFile and emojiFile must each declare their own `items` property for JsonAdapter to populate");
    }

    function test_cheatsheet_never_reads_the_nonexistent_adapter_root() {
        const cheatsheet = readSource("../../nix/home/quickshell/qml/cheatsheet/Cheatsheet.qml");
        verify(cheatsheet.indexOf(".adapter.root") === -1, "JsonAdapter has no `root` property on this Quickshell build — reading a bare root off it is silently always undefined");
    }

    function test_cheatsheet_declares_a_property_for_the_adapter_to_populate() {
        const cheatsheet = readSource("../../nix/home/quickshell/qml/cheatsheet/Cheatsheet.qml");
        verify(cheatsheet.indexOf("property var groups") !== -1, "JsonAdapter only populates a property declared on the adapter instance itself — keybindsFile's adapter needs a declared `groups` property");
    }

    // tree.nix, not Theme.qml: the generated file only exists inside a Nix
    // build's output, which this checkout does not ship, so the generator's
    // own source is the thing to pin. The property declaration this asserts
    // on sits inside a plain heredoc-style string with no Nix interpolation
    // around it, so it lands in the generated Theme.qml unchanged — verified
    // separately by building .#quickshell-config and reading that file back.
    function test_tree_nix_never_reads_the_nonexistent_adapter_root() {
        const tree = readSource("../../nix/home/quickshell/tree.nix");
        verify(tree.indexOf(".adapter.root") === -1, "JsonAdapter has no `root` property on this Quickshell build — reading a bare root off it is silently always undefined");
    }

    function test_tree_nix_declares_a_property_for_the_adapter_to_populate() {
        const tree = readSource("../../nix/home/quickshell/tree.nix");
        verify(tree.indexOf("property var accent") !== -1, "JsonAdapter only populates a property declared on the adapter instance itself — tintState's adapter needs a declared `accent` property");
    }
}
