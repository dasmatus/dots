// Parsing for the keymap pill: Hyprland's `activelayout` IPC payload, and
// the `hyprctl devices -j` snapshot the pill reads both to seed itself
// before the first such event arrives and to resolve every event after
// that. See activeLayoutCodeFrom for why the event's own payload is not
// enough on its own.
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
// for a 30px bar. A parenthesised variant is dropped before abbreviating.
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

// Picks the active layout's own configured code out of the same `hyprctl
// devices -j` snapshot, the same code launcher/keyboard.js's rows switch
// by (`Keyboard Layout: sk`), not `active_keymap` above. That field is
// Hyprland's human-readable XKB description, and truncating it does not
// generally land on the matching code: German's own code is "de", but its
// description starts "Ge"; Slovak's is "sk", but its description starts
// "Sl". Confirmed live (`hyprctl devices -j` on a running Hyprland session)
// that each keyboard also reports `layout`, the same comma-separated code
// list `hyprctl getoption input:kb_layout -j`'s `str` carries, and
// `active_layout_index`, which entry in it is live right now. Indexing one
// with the other is what this returns. Same fallbacks as activeKeymapFrom
// for no keyboards or unparseable JSON, plus "" for an index that is
// missing or out of range.
function activeLayoutCodeFrom(devicesJsonText) {
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
    const codes = (main.layout ?? "").split(",").map(code => code.trim());
    const index = main.active_layout_index;

    if (typeof index !== "number" || index < 0 || index >= codes.length)
        return "";

    return codes[index];
}

// How many layouts are configured for the active keyboard, out of the same
// snapshot activeLayoutCodeFrom reads, `layout` counted rather than
// indexed. Backs Keymap.qml's own `visible` guard: a single configured
// layout has nothing to switch between, the same floor
// launcher/keyboard.js's keyboardRows already applies before it offers a
// row, so the pill and the launcher agree on when there is nothing
// actionable here too.
function configuredLayoutCount(devicesJsonText) {
    let parsed;

    try {
        parsed = JSON.parse(devicesJsonText);
    } catch (e) {
        return 0;
    }

    const keyboards = parsed?.keyboards ?? [];
    if (keyboards.length === 0)
        return 0;

    const main = keyboards.find(keyboard => keyboard.main) ?? keyboards[0];
    return (main.layout ?? "").split(",").map(code => code.trim()).filter(code => code.length > 0).length;
}
