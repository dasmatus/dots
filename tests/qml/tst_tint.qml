// Per-target accent tint writers.
//
// Fixtures below are taken from rust/wallpaper-tui/tests/tint.rs's "pure
// writers" section (rofi_rasi_*, gtk_css_*, hyprland_borders_*,
// recolor_kvantum_*, recolor_icon_*) — the subset of that file's 20 tests
// that exercise the five functions this task ports. The other eleven
// (tint_kvantum_tree_*, tint_icon_tree_*, apply_tint_*,
// run_border_commands_*) drive filesystem trees and spawned processes that
// stay in the crate; there is nothing here to port them against yet.
//
// ACCENT/ACCENT_DARK/ACCENT_LIGHT match tint.rs's test constants exactly, so
// a fixture's expected substrings can be copied verbatim from the Rust
// source instead of re-derived.
import QtQuick
import QtTest
import "../../nix/home/quickshell/qml/wallpaper/tint.js" as Tint

TestCase {
    name: "Tint"

    readonly property string accent: "#ff00aa"
    readonly property string accentDark: "#330044"
    readonly property string accentLight: "#ffaadd"

    function test_rofi_rasi_text_data() {
        return [
            {
                tag: "replaces_accent_and_selected_bg",
                base: "* {\n  accent:      #7aa2f7;\n  selected-bg: #2d3252;\n  bg: #1a1b26;\n}\n",
                mustContain: ["accent:      #ff00aa;", "selected-bg: #330044;", "bg: #1a1b26;"]
            },
            {
                tag: "preserves_structure",
                base: "configuration { font: \"Lilex 12\"; }\n* { accent: #7aa2f7; }\nwindow { width: 720px; }\n",
                mustContain: ["Lilex 12", "width: 720px;"]
            }
        ];
    }

    function test_rofi_rasi_text(row) {
        const out = Tint.rofiRasiText(row.base, accent, accentDark);
        for (const needle of row.mustContain)
            verify(out.indexOf(needle) !== -1, out + " missing " + needle);
    }

    function test_gtk_css_data() {
        return [
            {
                tag: "v3_overrides_selection",
                version: 3,
                mustContain: [
                    "@define-color theme_selected_bg_color #ff00aa;",
                    "@define-color theme_unfocused_selected_bg_color #330044;"
                ],
                // v3 must NOT emit the gtk4-only accent_* colors.
                mustNotContain: ["accent_bg_color"]
            },
            {
                tag: "v4_overrides_accent",
                version: 4,
                mustContain: [
                    "@define-color accent_color #ff00aa;",
                    "@define-color accent_bg_color #ff00aa;",
                    "@define-color accent_fg_color #ffffff;"
                ],
                mustNotContain: []
            }
        ];
    }

    function test_gtk_css(row) {
        const css = Tint.gtkCss(accent, accentDark, accentLight, row.version);
        for (const needle of row.mustContain)
            verify(css.indexOf(needle) !== -1, css + " missing " + needle);
        for (const needle of row.mustNotContain)
            verify(css.indexOf(needle) === -1, css + " must not contain " + needle);
    }

    function test_hyprland_borders_skip_without_hyprland() {
        compare(Tint.hyprlandBorderCommands(null, accent, accentDark), null);
    }

    function test_hyprland_borders_emit_single_hl_config_eval() {
        const cmds = Tint.hyprlandBorderCommands("deadbeef", accent, accentDark);
        compare(cmds.length, 1); // one eval call sets both borders
        compare(cmds[0][0], "hyprctl");
        compare(cmds[0][1], "eval");
        const lua = cmds[0][2];
        verify(lua.indexOf("hl.config({") === 0, "flat-dotted hl.config call, got " + lua);
        verify(lua.indexOf("[\"general.col.active_border\"] = \"rgba(ff00aaff)\"") !== -1);
        verify(lua.indexOf("[\"general.col.inactive_border\"] = \"rgba(330044ff)\"") !== -1);
        verify(lua.indexOf("#") === -1, "rgba() takes bare hex, no leading '#': " + lua);
    }

    function test_hyprland_borders_never_use_retired_keyword_ipc() {
        const cmds = Tint.hyprlandBorderCommands("deadbeef", accent, accentDark);
        const flat = cmds.reduce((acc, c) => acc.concat(c), []);
        verify(flat.every((arg) => arg !== "keyword"),
               "hyprctl keyword is a silent no-op under the Lua parser (0.55+)");
    }

    function test_recolor_kvantum_preserves_alpha_and_neutrals() {
        const sample = "x:#8CAAEE y:#839EDD z:#98B2EF alpha:#8CAAEE4D neutral:#303446 text:#C6D0F5";
        const out = Tint.recolorKvantumText(sample, accent, accentDark, accentLight);
        verify(out.indexOf("#ff00aa") !== -1);
        verify(out.indexOf("#330044") !== -1);
        verify(out.indexOf("#ffaadd") !== -1);
        verify(out.indexOf("#ff00aa4D") !== -1, "trailing alpha hex must be preserved");
        verify(out.indexOf("#303446") !== -1 && out.indexOf("#C6D0F5") !== -1, "neutrals/text untouched");
        // original accents are gone (case-insensitive).
        verify(out.toLowerCase().indexOf("#8caaee") === -1);
    }

    // The alpha-preservation case: only the 7-char body is matched, so a
    // trailing alpha byte (lower- or upper-case) always survives untouched.
    function test_recolor_kvantum_preserves_alpha_suffix_data() {
        return [
            { tag: "lowercase_alpha", input: "#8caaeeff", expected: "#ff00aaff" },
            { tag: "uppercase_alpha", input: "#8CAAEEFF", expected: "#ff00aaFF" }
        ];
    }

    function test_recolor_kvantum_preserves_alpha_suffix(row) {
        compare(Tint.recolorKvantumText(row.input, accent, accentDark, accentLight), row.expected);
    }

    function test_recolor_icon_shifts_hue_keeps_lightness() {
        const sample = "a:#1c71d8 b:#438de6 c:#62a0ea d:#99c1f1 e:#afd4ff keep:#e78284";
        const out = Tint.recolorIconText(sample, accent);
        const accentHls = Tint.hexToHls(accent);
        const originals = ["#1c71d8", "#438de6", "#62a0ea", "#99c1f1", "#afd4ff"];
        for (const orig of originals) {
            const origHls = Tint.hexToHls(orig);
            const expected = Tint.hlsToHex(accentHls.h, origHls.l, accentHls.s);
            verify(out.indexOf(expected) !== -1, orig + " -> " + expected + " (preserved lightness) missing");
        }
        // a non-blue status color is left alone.
        verify(out.indexOf("#e78284") !== -1);
    }
}
