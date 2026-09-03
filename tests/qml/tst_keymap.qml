// Keymap pill parsing: Hyprland's `activelayout` event payload, the XKB
// layout-name shortener, and the `hyprctl devices -j` seed read.
import QtQuick
import QtTest
import "../../nix/home/quickshell/qml/bar/keymap.js" as Keymap

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
            { tag: "already short", name: "Sk", expected: "SK" }
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
}
