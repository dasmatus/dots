// Parsing for the keymap pill: Hyprland's `activelayout` IPC payload, the
// XKB layout names it carries, and the `hyprctl devices -j` snapshot used to
// seed the pill before the first such event ever arrives.
//
// Kept out of Keymap.qml for the same reason battery.js is kept out of
// Battery.qml: everything here is string and JSON handling over plain
// values, so tests/qml can drive it with fixture text and no Hyprland
// socket, no rawEvent signal and no compositor anywhere near the test.
.pragma library

// Hyprland writes `activelayout` events as `<keyboardname>,<layoutname>` on
// its IPC socket, forwarded verbatim through Hyprland.rawEvent's `data`
// field. Split on the first comma only, not every comma: a layout name is
// free text from the XKB database and nothing rules out one containing its
// own comma, while a keyboard's device name never does.
function parseActiveLayoutEvent(data) {
    const text = data ?? "";
    const comma = text.indexOf(",");

    if (comma === -1)
        return {
            keyboard: text,
            layout: ""
        };

    return {
        keyboard: text.slice(0, comma),
        layout: text.slice(comma + 1)
    };
}

// Shortens a full XKB layout name ("English (US)", "Slovak") to two letters
// for a 30px bar. A parenthesised variant is dropped before abbreviating —
// "(US)" describes a keyboard arrangement, not the language, and keeping it
// would abbreviate "English (US)" down to the variant instead of the
// language every other layout is identified by.
function shortenLayout(name) {
    const trimmed = (name ?? "").trim();

    if (trimmed === "")
        return "";

    const base = trimmed.replace(/\s*\([^)]*\)\s*$/, "");
    return base.slice(0, 2).toUpperCase();
}

// Picks the seed layout name out of `hyprctl devices -j`'s stdout, read once
// at startup because Hyprland.rawEvent only fires on a change and the pill
// would otherwise stay blank until the user's first switch. Prefers the
// keyboard hyprctl itself marks `main`; falls back to the first keyboard in
// the list on older Hyprland builds that never added that field, and to ""
// for anything JSON.parse cannot make sense of, e.g. a read that raced the
// socket coming up.
function activeKeymapFrom(devicesJsonText) {
    let parsed;

    try {
        parsed = JSON.parse(devicesJsonText);
    } catch (e) {
        return "";
    }

    const keyboards = parsed?.keyboards ?? [];
    if (keyboards.length === 0)
        return "";

    const main = keyboards.find(keyboard => keyboard.main) ?? keyboards[0];
    return main.active_keymap ?? "";
}
