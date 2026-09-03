// Pure logic for the launcher's keyboard-layout switcher.
//
// Hyprland's configured layouts live in `input:kb_layout`, a comma-separated
// list (e.g. "us,sk"), readable at runtime through
// `hyprctl getoption input:kb_layout -j`. Switching one is NOT a Hyprland
// dispatcher — `Hyprland.dispatch()` cannot reach it — the only way in is
// `hyprctl switchxkblayout <device> <cmd>`, where `<cmd>` is `next`, `prev`
// or an index into that same list. Both shapes were confirmed live against
// this machine's own running Hyprland instance rather than assumed from the
// brief:
//   $ hyprctl getoption input:kb_layout -j
//   {"option": "input:kb_layout", "str": "us", "set": true }
//   $ hyprctl switchxkblayout all 0
//   ok
//
// Kept out of Providers.qml so tests/qml/tst_keyboard.qml can drive it with
// captured getoption JSON and no Process, FileView or Quickshell singleton
// anywhere near the test — the same split status.js and its test already
// use for meminfo and df.
.pragma library

// Words a query might reasonably reach for that never appear in a row's own
// title ("Keyboard Layout: <code>"), mirroring status.js's DISK_LABELS
// keyword arrays: a title match alone would miss "kb", Hyprland's own
// config key, since "kb" is not a substring of "keyboard".
const KEYWORDS = ["keyboard", "layout", "kb", "language", "locale", "input"];

// `str` holds the effective value of input:kb_layout whether or not the
// user's own config actually sets it — an option nobody set still reports
// Hyprland's own "us" default here — so `set` is read for nothing; only
// `str` decides what this returns. Malformed JSON, a missing field, or an
// empty string all collapse to the same empty list a caller already has to
// handle (see keyboardRows below), never a thrown exception.
function parseConfiguredLayouts(rawJson) {
    let parsed;
    try {
        parsed = JSON.parse(rawJson);
    } catch (error) {
        return [];
    }

    if (typeof parsed?.str !== "string")
        return [];

    return parsed.str.split(",").map(code => code.trim()).filter(code => code.length > 0);
}

// hyprctl switchxkblayout takes an INDEX into input:kb_layout's own list,
// never the layout code itself, so the only thing this ever puts into argv
// is an integer keyboardRows computed from the list it already parsed —
// nothing a user typed or configured ever reaches this as a raw string.
// `device` is a parameter rather than the literal "all" hardcoded here so a
// test can pin the exact argv shape without caring what the caller chose.
function switchLayoutArgv(device, index) {
    return ["hyprctl", "switchxkblayout", device, String(index)];
}

// Whether `query` (already trimmed) answers to a layout row — same shape as
// status.js's answersTo, checked against the row's own title first and the
// shared KEYWORDS list second.
function answersTo(query, title) {
    if (query === "")
        return true;

    const needle = query.toLowerCase();
    if (title.toLowerCase().includes(needle))
        return true;

    return KEYWORDS.some(keyword => keyword.includes(needle));
}

// One row per configured layout, or none at all with fewer than two:
// Hyprland always answers getoption with a list, even a single-entry one, so
// "us" alone parses to exactly one row that would only ever switch onto the
// layout already active — a button that looks actionable and does nothing.
// The row's index is fixed by its position in `layouts`, the same order
// Hyprland enumerates them in, which is what keeps switchLayoutArgv's index
// argument meaning what active_layout_index means everywhere else.
//
// `exec` is a callback rather than Quickshell.execDetached called directly,
// the same split statusRows takes for `copy`, so this file never has to
// import Quickshell to be tested.
function keyboardRows(query, layouts, device, exec) {
    if (layouts.length < 2)
        return [];

    const rows = [];

    for (let index = 0; index < layouts.length; index++) {
        const code = layouts[index];
        const title = `Keyboard Layout: ${code}`;

        if (!answersTo(query, title))
            continue;

        rows.push({
            title: title,
            subtitle: `Switch every keyboard to "${code}"`,
            icon: "",
            accessory: "keyboard",
            provider: "keyboard",
            key: `keyboard:${code}`,
            run: () => exec(switchLayoutArgv(device, index))
        });
    }

    return rows;
}
