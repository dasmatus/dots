// Keymap pill parsing: Hyprland's `activelayout` event payload, the XKB
// layout-name shortener, and the `hyprctl devices -j` seed read.
import QtQuick
import QtTest
import "../../nix/home/desktop/quickshell/qml/bar/keymap.js" as Keymap

TestCase {
    name: "Keymap"

    function test_parseActiveLayoutEvent_splits_on_the_first_comma_data() {
        return [
            { tag: "typical", data: "at-translated-set-2-keyboard,English (US)", expectedKeyboard: "at-translated-set-2-keyboard", expectedLayout: "English (US)" },
            { tag: "layout name with its own comma", data: "kbd,Layout, With Comma", expectedKeyboard: "kbd", expectedLayout: "Layout, With Comma" },
            { tag: "no comma at all", data: "justtext", expectedKeyboard: "justtext", expectedLayout: "" }
        ];
    }

    function test_parseActiveLayoutEvent_splits_on_the_first_comma(row) {
        const parsed = Keymap.parseActiveLayoutEvent(row.data);
        compare(parsed.keyboard, row.expectedKeyboard);
        compare(parsed.layout, row.expectedLayout);
    }

    // Hyprland.rawEvent hands the data field over as a plain string, but a
    // handler that races the socket's own startup has seen undefined here
    // before; this must not throw.
    function test_parseActiveLayoutEvent_treats_a_missing_payload_as_empty() {
        const parsed = Keymap.parseActiveLayoutEvent(undefined);
        compare(parsed.keyboard, "");
        compare(parsed.layout, "");
    }

    function test_shortenLayout_drops_the_variant_and_abbreviates_data() {
        return [
            { tag: "english variant", name: "English (US)", expected: "EN" },
            { tag: "plain name", name: "Slovak", expected: "SL" },
            { tag: "german", name: "German", expected: "GE" },
            { tag: "already short", name: "Sk", expected: "SK" },
            // The pill's actual caller now: a bare XKB layout code, not a
            // human-readable description. No parenthetical to drop, so this
            // is just an uppercase pass-through for the common two-letter
            // case.
            { tag: "layout code", name: "sk", expected: "SK" },
            { tag: "another layout code", name: "us", expected: "US" }
        ];
    }

    function test_shortenLayout_drops_the_variant_and_abbreviates(row) {
        compare(Keymap.shortenLayout(row.name), row.expected);
    }

    function test_shortenLayout_is_total_for_empty_input() {
        compare(Keymap.shortenLayout(""), "");
        compare(Keymap.shortenLayout(undefined), "");
        compare(Keymap.shortenLayout(null), "");
    }

    function test_activeKeymapFrom_prefers_the_keyboard_marked_main() {
        const json = JSON.stringify({
            keyboards: [{ name: "virtual-kb", active_keymap: "English (US)", main: false }, { name: "real-kb", active_keymap: "Slovak (qwerty)", main: true }]
        });

        compare(Keymap.activeKeymapFrom(json), "Slovak (qwerty)");
    }

    // Older Hyprland builds never added the `main` field at all; the first
    // keyboard in the list is the only reasonable seed then.
    function test_activeKeymapFrom_falls_back_to_the_first_keyboard_when_none_is_main() {
        const json = JSON.stringify({
            keyboards: [{ name: "kb-a", active_keymap: "English (US)" }, { name: "kb-b", active_keymap: "German" }]
        });

        compare(Keymap.activeKeymapFrom(json), "English (US)");
    }

    function test_activeKeymapFrom_is_empty_for_no_keyboards() {
        compare(Keymap.activeKeymapFrom(JSON.stringify({ keyboards: [] })), "");
    }

    // The read this seeds from can race Hyprland's own socket coming up
    // (Watcher.qml's own header documents the same race for
    // `hyprctl monitors -j`), which prints nothing at all rather than valid
    // JSON. Must not throw.
    function test_activeKeymapFrom_is_empty_for_unparseable_text() {
        compare(Keymap.activeKeymapFrom(""), "");
        compare(Keymap.activeKeymapFrom("not json"), "");
    }

    // A real capture shape (`hyprctl devices -j` on a running Hyprland
    // session): `layout` is the configured code list, `active_layout_index`
    // says which entry is live. This is the field the launcher's own rows
    // already switch by, unlike active_keymap's human description above.
    function test_activeLayoutCodeFrom_indexes_a_multi_layout_list() {
        const json = JSON.stringify({
            keyboards: [{ name: "kb", main: true, layout: "us,sk", active_layout_index: 1 }]
        });

        compare(Keymap.activeLayoutCodeFrom(json), "sk");
    }

    function test_activeLayoutCodeFrom_prefers_the_keyboard_marked_main() {
        const json = JSON.stringify({
            keyboards: [{ name: "virtual-kb", main: false, layout: "us", active_layout_index: 0 }, { name: "real-kb", main: true, layout: "us,sk", active_layout_index: 1 }]
        });

        compare(Keymap.activeLayoutCodeFrom(json), "sk");
    }

    function test_activeLayoutCodeFrom_falls_back_to_the_first_keyboard_when_none_is_main() {
        const json = JSON.stringify({
            keyboards: [{ name: "kb-a", layout: "de", active_layout_index: 0 }, { name: "kb-b", layout: "fr", active_layout_index: 0 }]
        });

        compare(Keymap.activeLayoutCodeFrom(json), "de");
    }

    function test_activeLayoutCodeFrom_is_empty_for_no_keyboards() {
        compare(Keymap.activeLayoutCodeFrom(JSON.stringify({ keyboards: [] })), "");
    }

    function test_activeLayoutCodeFrom_is_empty_for_unparseable_text() {
        compare(Keymap.activeLayoutCodeFrom(""), "");
        compare(Keymap.activeLayoutCodeFrom("not json"), "");
    }

    // A read that raced the socket coming up, or an older Hyprland build
    // that never added the field, must not throw or index out of bounds.
    function test_activeLayoutCodeFrom_is_empty_for_a_missing_or_out_of_range_index() {
        const missingIndex = JSON.stringify({ keyboards: [{ main: true, layout: "us,sk" }] });
        const outOfRange = JSON.stringify({ keyboards: [{ main: true, layout: "us,sk", active_layout_index: 5 }] });

        compare(Keymap.activeLayoutCodeFrom(missingIndex), "");
        compare(Keymap.activeLayoutCodeFrom(outOfRange), "");
    }

    function test_configuredLayoutCount_counts_the_active_keyboards_layout_list() {
        const single = JSON.stringify({ keyboards: [{ main: true, layout: "us", active_layout_index: 0 }] });
        const multi = JSON.stringify({ keyboards: [{ main: true, layout: "us,sk,de", active_layout_index: 0 }] });

        compare(Keymap.configuredLayoutCount(single), 1);
        compare(Keymap.configuredLayoutCount(multi), 3);
    }

    function test_configuredLayoutCount_is_zero_for_no_keyboards_or_bad_json() {
        compare(Keymap.configuredLayoutCount(JSON.stringify({ keyboards: [] })), 0);
        compare(Keymap.configuredLayoutCount("not json"), 0);
    }
}
