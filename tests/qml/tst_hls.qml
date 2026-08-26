// RGB <-> HLS conversion.
//
// #7aa2f7 is the palette's accentFallback (nix/palette.json), so the round
// trip case is the actual colour Theme.qml falls back to, not an arbitrary
// one. Pure red is colorsys's own textbook case: maximal saturation, mid
// lightness, hue at the wheel's origin.
import QtQuick
import QtTest
import "../../nix/home/quickshell/qml/common/hls.js" as Hls

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
}
