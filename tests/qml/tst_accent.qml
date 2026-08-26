// accent.js's accentFrom, exercised against the Rust internal backend it was
// ported from rather than hand-picked expectations. Both oracle triples below
// came from a temporary `wallpaper-tui --dump-accent PATH` (added, used, and
// reverted — never `--output`, which would mutate the live desktop) run
// against the exact fixtures this file loads, so a divergence here is a port
// bug, not a stale expectation.
//
// Canvas is the only way to get decoded pixels into JS under qmltestrunner,
// and its readback needs `renderTarget: Canvas.Image` plus `loadImage` in
// `Component.onCompleted` — `onPaint` fires once loading completes and does
// the actual `drawImage`/`getImageData`. `drawImage` takes the SAME url
// string handed to `loadImage`, not an `Image` item (which draws transparent
// black with no error) and not some resolved variant of the string.
import QtQuick
import QtTest
import "../../nix/home/quickshell/qml/wallpaper/accent.js" as Accent

TestCase {
    name: "Accent"

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
    // `#000000` a naive port would return.
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
        compare(wallpaperCanvas.accent, "#d38069");
        compare(wallpaperCanvas.dark, "#9e472e");
        compare(wallpaperCanvas.light, "#e6b6a8");
    }

    function test_all_black_falls_back_to_the_default_accent() {
        tryCompare(blackCanvas, "ready", true, 5000);
        compare(blackCanvas.accent, "#7aa2f7");
        compare(blackCanvas.dark, "#3b4261");
        compare(blackCanvas.light, "#a9b1d6");
    }
}
