// RGB <-> HLS conversion.
//
// #7aa2f7 is the palette's accentFallback (nix/data/palette.json), so the round
// trip case is the actual colour Theme.qml falls back to, not an arbitrary
// one. Pure red is colorsys's own textbook case: maximal saturation, mid
// lightness, hue at the wheel's origin.
//
// None of the above ever exercises the fold hls.js's own header warns about:
// #7aa2f7 and pure red both land on non-negative hues (rem_euclid and JS's
// `%` agree once the numerator is already positive), the `g === maxc` hue
// branch, or v()'s hue < 1/6 ramp. The three tests below are chosen to fail
// if any of those broke, with expected values hand-derived from
// rust/wallpaper-tui/src/accent.rs's rgb_to_hls/hls_to_rgb rather than from
// hls.js itself, so a bug shared by both ports would still be caught.
import QtQuick
import QtTest
import "../../nix/home/desktop/quickshell/qml/common/hls.js" as Hls

TestCase {
    name: "Hls"

    function test_7aa2f7_survives_a_round_trip() {
        const r = 0x7a / 255;
        const g = 0xa2 / 255;
        const b = 0xf7 / 255;

        const hls = Hls.rgbToHls(r, g, b);
        const rgb = Hls.hlsToRgb(hls.h, hls.l, hls.s);

        fuzzyCompare(rgb.r, r, 0.0001);
        fuzzyCompare(rgb.g, g, 0.0001);
        fuzzyCompare(rgb.b, b, 0.0001);
    }

    function test_pure_red_gives_the_hls_extremes() {
        const hls = Hls.rgbToHls(1, 0, 0);

        compare(hls.h, 0);
        compare(hls.l, 0.5);
        compare(hls.s, 1);
    }

    // r == maxc and b > g: bc - gc is negative, so the raw hue (before the
    // /6 and the wrap) is -0.5. `rem_euclid` folds that to 11/12; a bare JS
    // `%` would instead leave it at -1/12. Getting 0.91666... rather than a
    // negative number is what proves the fold in wrap() actually runs.
    function test_a_red_dominant_hue_needs_the_negative_fold() {
        const hls = Hls.rgbToHls(1.0, 0.0, 0.5);

        fuzzyCompare(hls.h, 11 / 12, 0.0001);
        compare(hls.l, 0.5);
        compare(hls.s, 1);
    }

    // Green is the largest channel, so this is the one case the two other
    // rgbToHls tests never reach: the `g === maxc` branch (h = 2 + rc - bc).
    function test_a_green_dominant_colour_hits_the_g_max_branch() {
        const hls = Hls.rgbToHls(0.5, 1.0, 0.0);

        compare(hls.h, 0.25);
        compare(hls.l, 0.5);
        compare(hls.s, 1);
    }

    // h = 1/12 sits inside v()'s first sextant (hue < 1/6), and offsetting
    // it by +-1/3 for r and b lands those in the "return m2" and "return m1"
    // branches instead, so all three of v()'s non-trivial branches run in
    // one call. m1 = 0, m2 = 1 here, so the ramp branch's interpolation
    // (m1 + (m2 - m1) * hue * 6) has to actually compute 0.5 rather than
    // fall through to a boundary value by accident.
    function test_hls_to_rgb_walks_the_first_hue_ramp() {
        const rgb = Hls.hlsToRgb(1 / 12, 0.5, 1.0);

        fuzzyCompare(rgb.r, 1.0, 0.0001);
        fuzzyCompare(rgb.g, 0.5, 0.0001);
        fuzzyCompare(rgb.b, 0.0, 0.0001);
    }
}
