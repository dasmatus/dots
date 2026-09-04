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

    // Slices out each `JsonAdapter { ... }` body in source order, the same
    // scoping tst_tint_wiring.qml's applyAccentBody() uses on a function
    // body and for the same reason: Cheatsheet.qml's `groups` property and
    // its adapter's own declared `groups` property share a name, so an
    // unscoped `indexOf("property var groups")` is satisfied by the OUTER
    // `readonly property var groups: ...` line even when the adapter itself
    // never declares anything — exactly the pre-fix shape, where the block
    // was a bare `JsonAdapter {}`. Only a check confined to the block body
    // can tell "the adapter declares it" from "some other line nearby
    // happens to contain the same words".
    function jsonAdapterBlocks(source) {
        const marker = "JsonAdapter {";
        const blocks = [];
        let searchFrom = 0;

        while (true) {
            const start = source.indexOf(marker, searchFrom);
            if (start === -1)
                break;

            let depth = 0;
            let end = -1;
            for (let i = start + marker.length - 1; i < source.length; i++) {
                if (source[i] === "{")
                    depth++;
                else if (source[i] === "}") {
                    depth--;
                    if (depth === 0) {
                        end = i;
                        break;
                    }
                }
            }
            verify(end !== -1, "JsonAdapter block starting at " + start + " must have a matching closing brace");

            blocks.push(source.slice(start, end + 1));
            searchFrom = end + 1;
        }

        return blocks;
    }

    function test_providers_never_reads_the_nonexistent_adapter_root() {
        const providers = readSource("../../nix/home/desktop/quickshell/qml/launcher/Providers.qml");
        verify(providers.indexOf(".adapter.root") === -1, "JsonAdapter has no `root` property on this Quickshell build — reading a bare root off it is silently always undefined");
    }

    // Every JsonAdapter in the file needs its OWN declared property —
    // JsonAdapter only populates a property declared on the adapter instance
    // itself, and a shared instance is not an option since each FileView owns
    // a different JSON file.
    //
    // The expected count is derived from the source rather than written down:
    // a literal would have to be edited every time a provider legitimately
    // gains a file, and the failure it produced then would say "expected 4,
    // got 5" rather than naming the adapter that is actually wrong. Deriving
    // it means this test only ever fails for the reason it exists — an
    // adapter that declares nothing.
    //
    // The property NAME is deliberately not pinned either: `items`, `records`
    // and whatever a later file needs are all correct, and only the presence
    // of a declaration is the contract.
    function test_providers_declares_a_property_on_every_adapter() {
        const providers = readSource("../../nix/home/desktop/quickshell/qml/launcher/Providers.qml");
        const blocks = jsonAdapterBlocks(providers);
        const expected = providers.split("adapter: JsonAdapter").length - 1;

        verify(expected > 0, "Providers must have at least one JsonAdapter for this test to mean anything");
        compare(blocks.length, expected, "every `adapter: JsonAdapter` in Providers.qml must parse as a block");

        for (let i = 0; i < blocks.length; i++)
            verify(/property\s+var\s+\w+/.test(blocks[i]), "adapter block " + i + " needs a declared `property var` — JsonAdapter only populates a property declared on the adapter instance itself, so an adapter without one is silently always empty");
    }

    function test_cheatsheet_never_reads_the_nonexistent_adapter_root() {
        const cheatsheet = readSource("../../nix/home/desktop/quickshell/qml/cheatsheet/Cheatsheet.qml");
        verify(cheatsheet.indexOf(".adapter.root") === -1, "JsonAdapter has no `root` property on this Quickshell build — reading a bare root off it is silently always undefined");
    }

    function test_cheatsheet_declares_a_property_for_the_adapter_to_populate() {
        const cheatsheet = readSource("../../nix/home/desktop/quickshell/qml/cheatsheet/Cheatsheet.qml");
        const blocks = jsonAdapterBlocks(cheatsheet);

        compare(blocks.length, 1, "keybindsFile must declare exactly one JsonAdapter { ... }");
        verify(blocks[0].indexOf("property var groups") !== -1, "keybindsFile's own JsonAdapter block needs a declared `groups` property — JsonAdapter only populates a property declared on the adapter instance itself");
    }

    // tree.nix, not Theme.qml: the generated file only exists inside a Nix
    // build's output, which this checkout does not ship, so the generator's
    // own source is the thing to pin. The property declaration this asserts
    // on sits inside a plain heredoc-style string with no Nix interpolation
    // around it, so it lands in the generated Theme.qml unchanged — verified
    // separately by building .#quickshell-config and reading that file back.
    function test_tree_nix_never_reads_the_nonexistent_adapter_root() {
        const tree = readSource("../../nix/home/desktop/quickshell/tree.nix");
        verify(tree.indexOf(".adapter.root") === -1, "JsonAdapter has no `root` property on this Quickshell build — reading a bare root off it is silently always undefined");
    }

    function test_tree_nix_declares_a_property_for_the_adapter_to_populate() {
        const tree = readSource("../../nix/home/desktop/quickshell/tree.nix");
        const blocks = jsonAdapterBlocks(tree);

        compare(blocks.length, 1, "tintState must declare exactly one JsonAdapter { ... }");
        verify(blocks[0].indexOf("property var accent") !== -1, "tintState's own JsonAdapter block needs a declared `accent` property — JsonAdapter only populates a property declared on the adapter instance itself");
    }
}
