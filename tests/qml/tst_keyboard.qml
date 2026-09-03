// The launcher's keyboard-layout switcher. `realGetoptionSingle` below is a
// real capture from this machine (`hyprctl getoption input:kb_layout -j`),
// not invented text — this machine has exactly one layout configured, which
// is also the shape that must yield zero rows (see keyboard.js's own header
// for why a single-layout config has nothing to switch to).
// `getoptionMulti` is synthetic, built from the same field the real capture
// proved exists (`str`), extended to the comma-separated multi-layout shape
// the brief itself describes and this machine's config does not currently
// exercise.
import QtQuick
import QtTest
import "../../nix/home/quickshell/qml/launcher/keyboard.js" as KeyboardMath

TestCase {
    name: "Keyboard"

    function realGetoptionSingle() {
        return '{"option": "input:kb_layout", "str": "us", "set": true }';
    }

    function getoptionMulti() {
        return '{"option": "input:kb_layout", "str": "us,sk", "set": true }';
    }

    function getoptionMultiWithSpaces() {
        return '{"option": "input:kb_layout", "str": "us, sk , de", "set": true }';
    }

    function test_parseConfiguredLayouts_reads_the_real_single_layout_capture() {
        compare(KeyboardMath.parseConfiguredLayouts(realGetoptionSingle()), ["us"]);
    }

    function test_parseConfiguredLayouts_splits_a_comma_separated_list() {
        compare(KeyboardMath.parseConfiguredLayouts(getoptionMulti()), ["us", "sk"]);
    }

    function test_parseConfiguredLayouts_trims_whitespace_around_each_code() {
        compare(KeyboardMath.parseConfiguredLayouts(getoptionMultiWithSpaces()), ["us", "sk", "de"]);
    }

    function test_parseConfiguredLayouts_ignores_set_and_trusts_str_alone() {
        // An option nobody explicitly set still reports Hyprland's own
        // default in `str` — `set: false` must not turn that into an empty
        // read.
        compare(KeyboardMath.parseConfiguredLayouts('{"option": "input:kb_layout", "str": "us", "set": false }'), ["us"]);
    }

    function test_parseConfiguredLayouts_returns_empty_for_malformed_json() {
        compare(KeyboardMath.parseConfiguredLayouts("not json"), []);
    }

    function test_parseConfiguredLayouts_returns_empty_for_an_empty_string() {
        compare(KeyboardMath.parseConfiguredLayouts(""), []);
    }

    function test_parseConfiguredLayouts_returns_empty_when_str_is_missing() {
        compare(KeyboardMath.parseConfiguredLayouts('{"option": "input:kb_layout", "set": true }'), []);
    }

    function test_parseConfiguredLayouts_returns_empty_when_str_is_the_empty_string() {
        compare(KeyboardMath.parseConfiguredLayouts('{"option": "input:kb_layout", "str": "", "set": true }'), []);
    }

    function test_parseConfiguredLayouts_returns_empty_when_str_is_not_a_string() {
        compare(KeyboardMath.parseConfiguredLayouts('{"option": "input:kb_layout", "str": 5, "set": true }'), []);
    }

    // hyprctl switchxkblayout takes an index, never the layout code itself —
    // this pins that the index arrives as a string element of its own,
    // never concatenated with anything else.
    function test_switchLayoutArgv_places_the_index_as_its_own_element() {
        compare(KeyboardMath.switchLayoutArgv("all", 0), ["hyprctl", "switchxkblayout", "all", "0"]);
        compare(KeyboardMath.switchLayoutArgv("all", 2), ["hyprctl", "switchxkblayout", "all", "2"]);
    }

    // The device is never built from a layout code or user input in this
    // file — Providers.qml always passes the literal "all" — but the
    // builder itself must still carry whatever it is given as one intact
    // argv element rather than folding it into a shell string, the same
    // discipline tst_files_operations.qml pins for every builder in
    // operations.js.
    function test_switchLayoutArgv_keeps_the_device_as_its_own_argv_element() {
        const nasty = "; rm -rf ~";
        compare(KeyboardMath.switchLayoutArgv(nasty, 1), ["hyprctl", "switchxkblayout", nasty, "1"]);
    }

    function test_keyboardRows_returns_nothing_for_a_single_configured_layout() {
        compare(KeyboardMath.keyboardRows("", ["us"], "all", () => {}), []);
    }

    function test_keyboardRows_returns_nothing_for_zero_configured_layouts() {
        compare(KeyboardMath.keyboardRows("", [], "all", () => {}), []);
    }

    function test_keyboardRows_returns_one_row_per_layout_on_the_empty_query() {
        const rows = KeyboardMath.keyboardRows("", ["us", "sk"], "all", () => {});

        compare(rows.length, 2);
        compare(rows[0].title, "Keyboard Layout: us");
        compare(rows[1].title, "Keyboard Layout: sk");
    }

    function test_keyboardRows_row_shape_carries_what_the_launcher_needs() {
        const rows = KeyboardMath.keyboardRows("", ["us", "sk"], "all", () => {});

        compare(rows[0].provider, "keyboard");
        compare(rows[0].key, "keyboard:us");
        compare(rows[0].subtitle, "Switch every keyboard to \"us\"");
        verify(typeof rows[0].run === "function");
    }

    function test_keyboardRows_typing_a_layout_code_finds_only_that_row() {
        const rows = KeyboardMath.keyboardRows("sk", ["us", "sk"], "all", () => {});

        compare(rows.length, 1);
        compare(rows[0].title, "Keyboard Layout: sk");
    }

    // "kb" is not a substring of "keyboard" (k-e-y-b, not k-b), so this only
    // passes if the keyword list is checked and not just the title text.
    function test_keyboardRows_typing_kb_finds_every_row_via_keyword() {
        const rows = KeyboardMath.keyboardRows("kb", ["us", "sk"], "all", () => {});

        compare(rows.length, 2);
    }

    function test_keyboardRows_data() {
        return [
            { tag: "keyboard", query: "keyboard" },
            { tag: "layout", query: "layout" },
            { tag: "language", query: "language" },
            { tag: "locale", query: "locale" },
            { tag: "input", query: "input" }
        ];
    }

    function test_keyboardRows_typing_a_shared_keyword_finds_every_row(row) {
        const rows = KeyboardMath.keyboardRows(row.query, ["us", "sk"], "all", () => {});

        compare(rows.length, 2);
    }

    function test_keyboardRows_an_unrelated_query_finds_nothing() {
        const rows = KeyboardMath.keyboardRows("firefox", ["us", "sk"], "all", () => {});

        compare(rows.length, 0);
    }

    // The row at index 1 must switch to index 1, not index 0 — the bug an
    // off-by-one or a fixed index would produce, and one two identical
    // "us" entries could not catch, which is why the fixture uses three
    // distinct codes.
    function test_keyboardRows_run_fires_the_argv_for_its_own_index() {
        const calls = [];
        const rows = KeyboardMath.keyboardRows("", ["us", "sk", "de"], "all", argv => calls.push(argv));

        rows[2].run();

        compare(calls.length, 1);
        compare(calls[0], ["hyprctl", "switchxkblayout", "all", "2"]);
    }

    function test_keyboardRows_run_passes_the_device_through_unchanged() {
        const calls = [];
        const rows = KeyboardMath.keyboardRows("", ["us", "sk"], "some-device", argv => calls.push(argv));

        rows[0].run();

        compare(calls[0], ["hyprctl", "switchxkblayout", "some-device", "0"]);
    }
}
