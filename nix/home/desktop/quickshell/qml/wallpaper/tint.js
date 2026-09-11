// Per-target accent tint writers, plus the Papirus nearest-colour lookup.
// Pure (string/array in -> string/array out): nothing here touches the
// filesystem, spawns a process or repaints the live desktop the way
// tint.rs's tree tinters and apply_tint_ctx orchestrator do. Those stay in
// the crate, which still owns the wallpaper.
//
// rofiRasiText, gtkCss, hyprlandBorderCommands, recolorKvantumText and the
// hex/HLS helpers under them are a second port of tint.rs's "pure writers",
// kept separate from the crate rather than shared through an FFI boundary so
// this task could prove the maths without one; the two are exercised
// against the same fixtures, not the same source, the same way
// common/hls.js relates to accent.rs.
//
// nearestPapirusColor, circularHueDistance and
// ACHROMATIC_SATURATION_THRESHOLD have no tint.rs counterpart: Papirus's
// symlink-per-colour scheme (see Icons.qml) is new to this branch, so there
// is nothing in the crate to port them from or test them against.
.pragma library
.import "../common/hls.js" as Hls

// Catppuccin-Frappe-Blue accents used by the Kvantum base theme; replaced
// verbatim (case-insensitive), 7-char body only, so a trailing alpha hex
// (e.g. "#8caaee4D") survives untouched.
var KVANTUM_ACCENT_HEXES = ["#8caaee", "#839edd", "#98b2ef"];

// None of '#' or a hex digit is a regex metacharacter today, but the hex
// family above is data, not a literal pattern chosen for this code.
// Escaping keeps a future accent format change (e.g. an 8-char literal) from
// silently turning into a broken RegExp instead of a loud one.
function escapeRegExp(s) {
    return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

// "#rrggbb" -> 0-1 floats per channel, mirroring accent.rs's hex_to_rgb
// composed with the /255 in hex_to_hls. Only the first 6 hex digits after
// the '#' are read, so a trailing alpha byte is ignored here rather than
// rejected, the same way Rust's fixed-width `h[0..2]` etc. slicing is.
function hexToRgb(hex) {
    const h = hex.replace(/^#/, "");
    return {
        r: parseInt(h.slice(0, 2), 16) / 255.0,
        g: parseInt(h.slice(2, 4), 16) / 255.0,
        b: parseInt(h.slice(4, 6), 16) / 255.0
    };
}

// Rust's f64::round is half-away-from-zero; JS's Math.round is half-towards
// +Infinity, so the two disagree on negative halves (Math.round(-0.5) is 0,
// not -1). clampByte's input never actually goes negative for any accent
// this file is fed, but rgb_to_hex's doc calls out the rounding rule by name,
// so matching it exactly here, rather than relying on the difference never
// being reachable, is what keeps this a faithful port instead of a
// look-alike one.
function roundHalfAwayFromZero(x) {
    return x < 0 ? -Math.round(-x) : Math.round(x);
}

function clampByte(c) {
    const v = roundHalfAwayFromZero(c * 255.0);
    return Math.max(0, Math.min(255, v));
}

function toHexByte(n) {
    const s = n.toString(16);
    return s.length < 2 ? "0" + s : s;
}

// (r, g, b) 0-1 floats -> "#rrggbb", lowercase, matching accent.rs's
// rgb_to_hex format string exactly.
function rgbToHex(rgb) {
    return "#" + toHexByte(clampByte(rgb.r)) + toHexByte(clampByte(rgb.g)) + toHexByte(clampByte(rgb.b));
}

// "#rrggbb" -> {h, l, s}, the hex_to_rgb + rgb_to_hls composition accent.rs's
// hex_to_hls does.
function hexToHls(hex) {
    const rgb = hexToRgb(hex);
    return Hls.rgbToHls(rgb.r, rgb.g, rgb.b);
}

// (h, l, s) -> "#rrggbb", the hls_to_rgb + rgb_to_hex composition accent.rs's
// hls_to_hex does.
function hlsToHex(h, l, s) {
    return rgbToHex(Hls.hlsToRgb(h, l, s));
}

// Substitute the `accent:` and `selected-bg:` rasi vars in the base text;
// every other line (fonts, window geometry, untouched colour vars) survives
// verbatim because only these two patterns ever match.
function rofiRasiText(base, accent, accentDark) {
    let out = base.replace(/(accent:\s*)#[0-9a-fA-F]{6};/g, (m, p1) => p1 + accent + ";");
    out = out.replace(/(selected-bg:\s*)#[0-9a-fA-F]{6};/g, (m, p1) => p1 + accentDark + ";");
    return out;
}

// `@define-color` overrides loaded after the Tokyonight theme import. This
// GENERATES a stylesheet from scratch. Unlike rofiRasiText it does not
// rewrite a base string, because GTK's own base theme already ships the
// selectors this only needs to override. version is 3 or 4; accentLight is
// accepted for signature parity with tint.rs's gtk_css but unused, because
// neither GTK version's accent story needs a third shade.
function gtkCss(accent, accentDark, accentLight, version) {
    if (version === 4) {
        return "/* wallpaper-tui accent tint — overrides Tokyonight accent. */\n"
            + "@define-color theme_selected_bg_color " + accent + ";\n"
            + "@define-color theme_selected_fg_color #ffffff;\n"
            + "@define-color accent_color " + accent + ";\n"
            + "@define-color accent_bg_color " + accent + ";\n"
            + "@define-color accent_fg_color #ffffff;\n";
    }
    return "/* wallpaper-tui accent tint — overrides Tokyonight selection. */\n"
        + "@define-color theme_selected_bg_color " + accent + ";\n"
        + "@define-color theme_selected_fg_color #ffffff;\n"
        + "@define-color theme_selected_borders_color " + accentDark + ";\n"
        + "@define-color theme_unfocused_selected_bg_color " + accentDark + ";\n";
}

// `hyprctl eval` argv setting both border colors through one
// `hl.config({...})` call with flat dotted string keys, e.g.
// `["general.col.active_border"]`. That's the HL.ConfigKey vocabulary
// `hl.get_config` reads back, not the nested `HL.ConfigOpt` shape
// `hl.config`'s own declared parameter type uses (both apply at runtime; the
// flat form needs no intermediate table construction). Deliberately never
// the legacy `hyprctl keyword` IPC: Hyprland 0.55+'s Lua config parser turns
// that into a silent no-op (exits 0, changes nothing). `rgba()` takes bare
// hex, so the accents' leading '#' is stripped. Returns null when Hyprland
// is not running (his is null/undefined), mirroring tint.rs's
// `Option<Vec<Vec<String>>>`.
function hyprlandBorderCommands(his, accent, accentDark) {
    if (his === null || his === undefined) {
        return null;
    }
    const active = accent.replace(/^#/, "");
    const inactive = accentDark.replace(/^#/, "");
    return [[
        "hyprctl",
        "eval",
        "hl.config({ [\"general.col.active_border\"] = \"rgba(" + active + "ff)\", "
            + "[\"general.col.inactive_border\"] = \"rgba(" + inactive + "ff)\" })"
    ]];
}

// Replace the Catppuccin-Frappe accent family; case-insensitive, matching
// only the 7-char `#rrggbb` body, so any characters immediately after a hit
// (a trailing alpha byte such as "4D") are never part of the match and land
// back in the output untouched. Pairs are applied in order and sequentially,
// same as tint.rs's loop over the same triples.
function recolorKvantumText(text, accent, accentDark, accentLight) {
    const pairs = [
        [KVANTUM_ACCENT_HEXES[0], accent],
        [KVANTUM_ACCENT_HEXES[1], accentDark],
        [KVANTUM_ACCENT_HEXES[2], accentLight]
    ];
    let out = text;
    for (const pair of pairs) {
        const re = new RegExp(escapeRegExp(pair[0]), "gi");
        out = out.replace(re, () => pair[1]);
    }
    return out;
}

// Below this saturation a colour reads as black/grey/white rather than any
// particular hue, so its hue is meaningless to compare against. hexToHls's
// own achromatic branch always answers h=0 for such a colour (see hls.js),
// which would otherwise make it look deceptively "hue-close" to red. Sits in
// the gap papirus-colors.json actually has between its four fully-achromatic
// entries (black/grey/white/yaru, s=0 exactly) and its next-lowest chromatic
// one (bluegrey, s≈0.18), so anything in (0, 0.18) draws the same line; 0.1
// leaves a wide margin on both sides.
var ACHROMATIC_SATURATION_THRESHOLD = 0.1;

// Hue wraps at 1.0, so h=0.02 and h=0.98 are 0.04 apart on the colour
// wheel, not the 0.96 a plain subtraction would read. Going the other way
// around the circle is shorter whenever the direct gap exceeds half a turn.
function circularHueDistance(a, b) {
    const d = Math.abs(a - b);
    return Math.min(d, 1.0 - d);
}

// Nearest Papirus folder-colour NAME for an arbitrary accent hex, so
// Icons.qml can symlink to a prebuilt colour variant instead of rewriting
// SVGs the way MoreWaita's retint() used to. `colors` is name -> hex
// (papirus-colors.json, parsed by the caller) and stays a parameter rather
// than a module-level table so this function stays pure and callers,
// including tests, can supply their own fixture table without depending on
// the live Papirus package.
//
// Candidates are first split by ACHROMATIC_SATURATION_THRESHOLD into an
// achromatic bucket and a chromatic one, and only the bucket matching the
// accent's own classification is searched, symmetrically, so a vivid
// accent can never land on grey (hue would be a false match, per the
// threshold's own comment) and a near-grey accent can never be dragged onto
// a vivid hue by hue arithmetic that is meaningless for it. If a caller's
// table has nothing in the matching bucket, the search falls back to the
// full table rather than returning nothing.
//
// The chromatic and achromatic buckets are then scored on different single
// axes. See the loop below for why.
//
// Ties (equal distance) resolve to whichever candidate's key comes first in
// `colors`'s own iteration order, because the scan keeps the first minimum
// it finds and only replaces it on a strictly smaller distance. So the
// same table and input always return the same name.
function nearestPapirusColor(accentHex, colors) {
    const accentHls = hexToHls(accentHex);
    const accentIsAchromatic = accentHls.s < ACHROMATIC_SATURATION_THRESHOLD;

    const entries = Object.keys(colors).map((name) => ({ name: name, hls: hexToHls(colors[name]) }));
    const sameBucket = entries.filter((entry) => (entry.hls.s < ACHROMATIC_SATURATION_THRESHOLD) === accentIsAchromatic);
    const candidates = sameBucket.length > 0 ? sameBucket : entries;

    let best = candidates[0];
    let bestDistance = Infinity;
    for (const entry of candidates) {
        // accent.js's accentFrom pins EVERY accent it produces onto a fixed
        // lightness and saturation (hlsToHex(hue, 0.62, 0.55), see
        // accent.js). Only hue ever varies. So for the chromatic bucket, a
        // distance built on dl/ds is not scoring the accent against a
        // candidate; it is scoring each candidate against a constant that
        // is the same for every call, which swamps the one term (hue) that
        // actually carries information and made most of the table
        // unreachable. Hue alone is what the plan specified and what
        // matches reality here. The achromatic bucket has the opposite
        // problem: hue is meaningless there (hexToHls's achromatic branch
        // always answers h=0, so every achromatic candidate would tie on
        // hue), so it is scored on lightness instead. That's the one axis
        // that still tells black, grey and white apart.
        const distance = accentIsAchromatic
            ? Math.abs(accentHls.l - entry.hls.l)
            : circularHueDistance(accentHls.h, entry.hls.h);
        if (distance < bestDistance) {
            bestDistance = distance;
            best = entry;
        }
    }
    return best.name;
}
