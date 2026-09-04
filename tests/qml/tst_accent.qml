// accent.js's accentFrom, exercised against the Rust internal backend it was
// ported from rather than hand-picked expectations. Every oracle triple below
// came from a temporary `wallpaper-tui --dump-accent PATH` (added, used, and
// reverted — never `--output`, which would mutate the live desktop) run
// against the exact fixtures this file loads, so a divergence here is a port
// bug, not a stale expectation.
//
// Canvas is the only way to get decoded pixels into JS under qmltestrunner,
// and its readback needs `renderTarget: Canvas.Image` plus `loadImage` in
// `Component.onCompleted`. `onPaint` does NOT fire only once loading
// completes: Canvas also paints once implicitly, on creation, before
// `loadImage`'s decode has had a chance to finish. `drawImage(url)` against
// a still-loading image draws nothing, so that implicit paint reads back as
// an all-transparent buffer and accentFrom falls back to DEFAULT_ACCENT —
// and under load that implicit paint reliably beat the real, post-decode
// one, flipping `ready` true on the fallback value before `tryCompare`
// below ever looked (confirmed by tagging every paint with
// `isImageLoaded(url)` and forcing it under CPU contention: the wrong
// paint landed first in the large majority of runs). Every `onPaint` below
// is guarded on `isImageLoaded(url)` so only the real paint ever sets
// `ready`. `drawImage` takes the SAME url string handed to `loadImage`, not
// an `Image` item (which draws transparent black with no error) and not
// some resolved variant of the string.
//
// `red.png`/`green.png`/`blue.png` are 64x64 solid-colour LOSSLESS PNGs: at
// 64x64 accent.rs's `thumbnail(64, 64)` is a documented no-op and Canvas
// draws them 1:1, so both pipelines see identical bytes and every channel
// must match the oracle exactly. `wallhaven-7jeozo.jpg` is the one fixture
// where that no longer holds — see its test below for why it gets a
// tolerance instead.
//
// The last group of tests below calls `Accent.accentFrom` directly on a
// hand-built `Uint8ClampedArray`, no Canvas or fixture file involved: they
// pin the pixel-filter boundaries and the tie-break rule that a subtly wrong
// port could get past the fixture-based tests above.
import QtQuick
import QtTest
import "../../nix/home/desktop/quickshell/qml/wallpaper/accent.js" as Accent

TestCase {
    name: "Accent"

    function hexToRgb(hex) {
        return {
            r: parseInt(hex.substr(1, 2), 16),
            g: parseInt(hex.substr(3, 2), 16),
            b: parseInt(hex.substr(5, 2), 16)
        };
    }

    // Rust and Qt decode the JPEG with two different decoders and scale it
    // with two different filters (accent.rs's `thumbnail` is a bespoke
    // integer box filter; Canvas's is opaque), so a real photo can come out
    // 1/255 apart in a channel even though the port's arithmetic is bit-exact
    // — confirmed by the solid-colour fixtures below, which take the same
    // arithmetic through no resize/decode variable and match exactly. This
    // test guards the end-to-end pipeline (decode + resize + bucket), not
    // the bucket arithmetic itself, so it gets a +/-1-per-channel tolerance
    // instead of the exact match every other test in this file asserts.
    function compareWithinOne(actualHex, expectedHex, label) {
        const a = hexToRgb(actualHex);
        const e = hexToRgb(expectedHex);
        verify(Math.abs(a.r - e.r) <= 1, label + " r: " + actualHex + " vs " + expectedHex);
        verify(Math.abs(a.g - e.g) <= 1, label + " g: " + actualHex + " vs " + expectedHex);
        verify(Math.abs(a.b - e.b) <= 1, label + " b: " + actualHex + " vs " + expectedHex);
    }

    // 1920x1080 fits accent.rs's `thumbnail(64, 64)` bounding box at exactly
    // 64x36 (1080 * 64/1920 = 36, no rounding), so this canvas downsamples
    // the same way the Rust extractor's thumbnail step does.
    Canvas {
        id: wallpaperCanvas
        readonly property string url: "../../Wallpapers/wh/wallhaven-7jeozo.jpg"
        renderTarget: Canvas.Image
        width: 64
        height: 36
        property bool ready: false
        property string accent: ""
        property string dark: ""
        property string light: ""

        Component.onCompleted: loadImage(url)
        onImageLoaded: requestPaint()
        onPaint: {
            // Skips Canvas's implicit pre-decode paint — see the file header.
            if (!isImageLoaded(url))
                return;
            const ctx = getContext("2d");
            ctx.drawImage(url, 0, 0, width, height);
            const result = Accent.accentFrom(ctx.getImageData(0, 0, width, height).data);
            accent = result.accent;
            dark = result.dark;
            light = result.light;
            ready = true;
        }
    }

    // All-black: every pixel's lightness is 0, outside accent.rs's
    // `0.1..=0.9` filter, so all 16 bins stay empty and
    // `try_extract_accent_internal` returns `None` — `extract_accent` then
    // falls back to `DEFAULT_ACCENT`/`_DARK`/`_LIGHT` rather than the
    // `#000000` a naive port would return. `test_accent_from_an_all_black_buffer_falls_back`
    // below pins the same behaviour straight off `accentFrom` with no image
    // involved; this Canvas version corroborates that the PNG/decode path
    // agrees with it end to end.
    Canvas {
        id: blackCanvas
        readonly property string url: "fixtures/black.png"
        renderTarget: Canvas.Image
        width: 64
        height: 64
        property bool ready: false
        property string accent: ""
        property string dark: ""
        property string light: ""

        Component.onCompleted: loadImage(url)
        onImageLoaded: requestPaint()
        onPaint: {
            // Skips Canvas's implicit pre-decode paint — see the file header.
            if (!isImageLoaded(url))
                return;
            const ctx = getContext("2d");
            ctx.drawImage(url, 0, 0, width, height);
            const result = Accent.accentFrom(ctx.getImageData(0, 0, width, height).data);
            accent = result.accent;
            dark = result.dark;
            light = result.light;
            ready = true;
        }
    }

    // Solid 64x64 fixtures, one per hue: at this exact size accent.rs's
    // `thumbnail(64, 64)` is a documented no-op and Canvas draws 1:1, so
    // there is no resize and no lossy re-encode between the oracle and this
    // test — the one difference the JPEG test above has to tolerate is gone,
    // and these three assert the oracle exactly.
    Canvas {
        id: redCanvas
        readonly property string url: "fixtures/red.png"
        renderTarget: Canvas.Image
        width: 64
        height: 64
        property bool ready: false
        property string accent: ""
        property string dark: ""
        property string light: ""

        Component.onCompleted: loadImage(url)
        onImageLoaded: requestPaint()
        onPaint: {
            // Skips Canvas's implicit pre-decode paint — see the file header.
            if (!isImageLoaded(url))
                return;
            const ctx = getContext("2d");
            ctx.drawImage(url, 0, 0, width, height);
            const result = Accent.accentFrom(ctx.getImageData(0, 0, width, height).data);
            accent = result.accent;
            dark = result.dark;
            light = result.light;
            ready = true;
        }
    }

    Canvas {
        id: greenCanvas
        readonly property string url: "fixtures/green.png"
        renderTarget: Canvas.Image
        width: 64
        height: 64
        property bool ready: false
        property string accent: ""
        property string dark: ""
        property string light: ""

        Component.onCompleted: loadImage(url)
        onImageLoaded: requestPaint()
        onPaint: {
            // Skips Canvas's implicit pre-decode paint — see the file header.
            if (!isImageLoaded(url))
                return;
            const ctx = getContext("2d");
            ctx.drawImage(url, 0, 0, width, height);
            const result = Accent.accentFrom(ctx.getImageData(0, 0, width, height).data);
            accent = result.accent;
            dark = result.dark;
            light = result.light;
            ready = true;
        }
    }

    Canvas {
        id: blueCanvas
        readonly property string url: "fixtures/blue.png"
        renderTarget: Canvas.Image
        width: 64
        height: 64
        property bool ready: false
        property string accent: ""
        property string dark: ""
        property string light: ""

        Component.onCompleted: loadImage(url)
        onImageLoaded: requestPaint()
        onPaint: {
            // Skips Canvas's implicit pre-decode paint — see the file header.
            if (!isImageLoaded(url))
                return;
            const ctx = getContext("2d");
            ctx.drawImage(url, 0, 0, width, height);
            const result = Accent.accentFrom(ctx.getImageData(0, 0, width, height).data);
            accent = result.accent;
            dark = result.dark;
            light = result.light;
            ready = true;
        }
    }

    function test_wallpaper_accent_matches_the_internal_backend_oracle() {
        tryCompare(wallpaperCanvas, "ready", true, 5000);
        compareWithinOne(wallpaperCanvas.accent, "#d38069", "accent");
        compareWithinOne(wallpaperCanvas.dark, "#9e472e", "dark");
        compareWithinOne(wallpaperCanvas.light, "#e6b6a8", "light");
    }

    function test_all_black_falls_back_to_the_default_accent() {
        tryCompare(blackCanvas, "ready", true, 5000);
        compare(blackCanvas.accent, "#7aa2f7");
        compare(blackCanvas.dark, "#3b4261");
        compare(blackCanvas.light, "#a9b1d6");
    }

    function test_solid_red_matches_the_internal_backend_oracle_exactly() {
        tryCompare(redCanvas, "ready", true, 5000);
        compare(redCanvas.accent, "#d36969");
        compare(redCanvas.dark, "#9e2e2e");
        compare(redCanvas.light, "#e6a8a8");
    }

    function test_solid_green_matches_the_internal_backend_oracle_exactly() {
        tryCompare(greenCanvas, "ready", true, 5000);
        compare(greenCanvas.accent, "#69d373");
        compare(greenCanvas.dark, "#2e9e39");
        compare(greenCanvas.light, "#a8e6ae");
    }

    function test_solid_blue_matches_the_internal_backend_oracle_exactly() {
        tryCompare(blueCanvas, "ready", true, 5000);
        compare(blueCanvas.accent, "#6983d3");
        compare(blueCanvas.dark, "#2e4a9e");
        compare(blueCanvas.light, "#a8b7e6");
    }

    // No Canvas, no fixture: `accentFrom` takes a plain RGBA quad stream, so
    // its edge cases are pinned directly against hand-built buffers whose
    // hue/lightness/saturation were solved for by hand from accent.rs's own
    // formulas (colorsys rgb_to_hls/hls_to_rgb), not read back off accent.js.

    // All 4 bytes black: l=0 for every pixel, outside `0.1..=0.9`, so every
    // bin stays empty and accentFrom must take the `best === -1` branch to
    // the default triple rather than, say, rounding black itself to a hex
    // colour.
    function test_accent_from_an_all_black_buffer_falls_back() {
        const pixels = new Uint8ClampedArray([0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255]);
        const result = Accent.accentFrom(pixels);
        compare(result.accent, "#7aa2f7");
        compare(result.dark, "#3b4261");
        compare(result.light, "#a9b1d6");
    }

    // (200,120,80) and (80,200,120) are the same (r,g,b) byte set rotated
    // through the three channels, so rgb_to_hls's max/min pair — and hence l
    // and s — are bit-for-bit identical between them (same division, same
    // operands, just relabelled), while the hue differs by a third of a turn
    // (h=1/18 -> bin 0, h=7/18 -> bin 6). One pixel per bin means each bin's
    // saturation-weighted vote IS that pixel's s, so this is an exact tie
    // across bins 0 and 6, not an approximate one.
    //
    // Rust's `Iterator::max_by` returns the LAST of equally-maximum elements
    // when scanning bins 0..15 in order, so bin 6 (the higher index) must
    // win over bin 0. A `>` in the port's bin-scan would leave the first
    // max (bin 0) in place instead and fail this test; only `>=` reproduces
    // Rust's last-wins tie-break. Expected hex values were solved by hand
    // from bin 6's hue (7/18) through hls_to_rgb at L=0.62/0.40/0.78, S=0.55.
    function test_tie_break_prefers_the_last_equally_weighted_bin() {
        const pixels = new Uint8ClampedArray([200, 120, 80, 255, 80, 200, 120, 255]);
        const result = Accent.accentFrom(pixels);
        compare(result.accent, "#69d38c");
        compare(result.dark, "#2e9e53");
        compare(result.light, "#a8e6bd");
    }

    // l == 0.1 exactly (bytes 51,0,25: minc=0 so l is exactly max/2, no
    // rounding on the low side). accent.rs's filter is `(0.1..=0.9).contains`
    // — inclusive — so this pixel must survive and produce the hue's derived
    // triple. A `l > 0.1` slip would discard it and fall back to
    // DEFAULT_ACCENT instead.
    function test_pixel_at_the_lightness_lower_bound_is_not_discarded() {
        const pixels = new Uint8ClampedArray([51, 0, 25, 255]);
        const result = Accent.accentFrom(pixels);
        compare(result.accent, "#d3699d");
        compare(result.dark, "#9e2e65");
        compare(result.light, "#e6a8c6");
    }

    // l == 0.9 exactly (bytes 255,204,230: maxc=1.0 exactly, so l is exactly
    // (1+minc)/2 with no rounding on the high side). Same inclusive bound as
    // above, at the other edge: a `l < 0.9` slip would discard this pixel.
    function test_pixel_at_the_lightness_upper_bound_is_not_discarded() {
        const pixels = new Uint8ClampedArray([255, 204, 230, 255]);
        const result = Accent.accentFrom(pixels);
        compare(result.accent, "#d3699f");
        compare(result.dark, "#9e2e67");
        compare(result.light, "#e6a8c8");
    }

    // s == 0.2 exactly (bytes 72,60,48: (72-48)/(72+48) = 0.2 bit-for-bit,
    // solved by search rather than by hand since rgb_to_hls rounds r/g/b/255
    // individually before the subtraction). accent.rs discards on `s < 0.2`,
    // so s == 0.2 is the lowest saturation that must still survive; a
    // `s > 0.2` slip would discard it and fall back to DEFAULT_ACCENT.
    function test_pixel_at_the_saturation_lower_bound_is_not_discarded() {
        const pixels = new Uint8ClampedArray([72, 60, 48, 255]);
        const result = Accent.accentFrom(pixels);
        compare(result.accent, "#d39e69");
        compare(result.dark, "#9e662e");
        compare(result.light, "#e6c7a8");
    }
}
