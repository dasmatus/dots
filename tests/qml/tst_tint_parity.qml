// Proves the join between accent.js and tint.js reproduces the crate end to
// end: decode a fixture's pixels, feed them through accentFrom, then feed
// that accent through hyprlandBorderCommands, and compare the resulting
// hyprctl argv against the crate's own hyprland_border_commands_for for the
// same accent. tst_accent.qml (task 1) pinned accentFrom against the crate's
// accent extractor; tst_tint.qml (task 2) pinned the writers against
// hand-written fixtures; neither exercises the two chained together the way
// tint.rs's apply_tint_ctx actually does — this is that join.
//
// Oracle capture: a temporary `--dump-tint-parity <path>` argument was added
// to rust/wallpaper-tui's cli.rs (an `Option<String>`) and handled in
// main.rs — prints `extract_accent(path, TintBackend::Internal)` and
// `hyprland_border_commands_for` for that accent, once with `his = None` and
// once with `his = Some("deadbeef")` (a fixed instance signature, so the
// argv is reproducible instead of depending on a live Hyprland session), as
// one JSON line, then exits before touching `--output` or anything else
// that mutates the live desktop. Run against
// tests/qml/fixtures/{red,green,blue}.png, then both files were
// `git checkout`-reverted; `git diff -- rust/` was confirmed empty
// afterwards. The accent/dark values below match tst_accent.qml's own
// oracle exactly (both come from the same `extract_accent` call) — this
// file does not re-derive them, only carries the join's expected argv
// forward from the same capture.
import QtQuick
import QtTest
import "../../nix/home/quickshell/qml/wallpaper/accent.js" as Accent
import "../../nix/home/quickshell/qml/wallpaper/tint.js" as Tint

TestCase {
    name: "TintParity"

    // The fixed instance signature the oracle capture used.
    readonly property string his: "deadbeef"

    // 64x64 solid-colour lossless PNGs: accent.rs's `thumbnail(64, 64)` is a
    // documented no-op at this size and Canvas draws them 1:1, so there is
    // no resize/decode variable between the oracle and this test (same
    // reasoning tst_accent.qml's red/green/blue Canvas tests rely on).
    Canvas {
        id: redCanvas
        readonly property string url: "fixtures/red.png"
        renderTarget: Canvas.Image
        width: 64
        height: 64
        property bool ready: false
        property var triple: null
        property var commands: null

        Component.onCompleted: loadImage(url)
        onImageLoaded: requestPaint()
        onPaint: {
            const ctx = getContext("2d");
            ctx.drawImage(url, 0, 0, width, height);
            triple = Accent.accentFrom(ctx.getImageData(0, 0, width, height).data);
            commands = Tint.hyprlandBorderCommands(his, triple.accent, triple.dark);
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
        property var triple: null
        property var commands: null

        Component.onCompleted: loadImage(url)
        onImageLoaded: requestPaint()
        onPaint: {
            const ctx = getContext("2d");
            ctx.drawImage(url, 0, 0, width, height);
            triple = Accent.accentFrom(ctx.getImageData(0, 0, width, height).data);
            commands = Tint.hyprlandBorderCommands(his, triple.accent, triple.dark);
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
        property var triple: null
        property var commands: null

        Component.onCompleted: loadImage(url)
        onImageLoaded: requestPaint()
        onPaint: {
            const ctx = getContext("2d");
            ctx.drawImage(url, 0, 0, width, height);
            triple = Accent.accentFrom(ctx.getImageData(0, 0, width, height).data);
            commands = Tint.hyprlandBorderCommands(his, triple.accent, triple.dark);
            ready = true;
        }
    }

    // Element-by-element rather than a whole-array compare(): QtTest's
    // compare() does not deep-compare nested JS arrays, so the length and
    // every element (array length, then string) must be checked explicitly
    // for the parity to actually be verified rather than silently passed.
    function verifyArgv(actual, expected, label) {
        compare(actual.length, expected.length, label + ": argv row count");
        for (let i = 0; i < expected.length; i++) {
            compare(actual[i].length, expected[i].length, label + ": row " + i + " element count");
            for (let j = 0; j < expected[i].length; j++)
                compare(actual[i][j], expected[i][j], label + ": row " + i + " element " + j);
        }
    }

    function test_red_reproduces_the_crates_hyprland_border_argv() {
        tryCompare(redCanvas, "ready", true, 5000);
        compare(redCanvas.triple.accent, "#d36969");
        compare(redCanvas.triple.dark, "#9e2e2e");
        verifyArgv(redCanvas.commands, [[
            "hyprctl",
            "eval",
            "hl.config({ [\"general.col.active_border\"] = \"rgba(d36969ff)\", " +
                "[\"general.col.inactive_border\"] = \"rgba(9e2e2eff)\" })"
        ]], "red");
    }

    function test_green_reproduces_the_crates_hyprland_border_argv() {
        tryCompare(greenCanvas, "ready", true, 5000);
        compare(greenCanvas.triple.accent, "#69d373");
        compare(greenCanvas.triple.dark, "#2e9e39");
        verifyArgv(greenCanvas.commands, [[
            "hyprctl",
            "eval",
            "hl.config({ [\"general.col.active_border\"] = \"rgba(69d373ff)\", " +
                "[\"general.col.inactive_border\"] = \"rgba(2e9e39ff)\" })"
        ]], "green");
    }

    function test_blue_reproduces_the_crates_hyprland_border_argv() {
        tryCompare(blueCanvas, "ready", true, 5000);
        compare(blueCanvas.triple.accent, "#6983d3");
        compare(blueCanvas.triple.dark, "#2e4a9e");
        verifyArgv(blueCanvas.commands, [[
            "hyprctl",
            "eval",
            "hl.config({ [\"general.col.active_border\"] = \"rgba(6983d3ff)\", " +
                "[\"general.col.inactive_border\"] = \"rgba(2e4a9eff)\" })"
        ]], "blue");
    }

    // The crate's `hyprland_border_commands_for` returns `None` when `his` is
    // `None` (its whole body is `his?` before touching `accent`/`accent_dark`
    // at all), so the oracle capture recorded `his_none: null` for every
    // fixture regardless of its accent. Reusing each fixture's own extracted
    // accent (rather than a hand-picked one) keeps this inside the same join
    // the rest of this file is proving, not a generic unit fact tst_tint.qml
    // already covers on its own.
    function test_no_instance_signature_yields_null_for_every_fixture() {
        tryCompare(redCanvas, "ready", true, 5000);
        compare(Tint.hyprlandBorderCommands(null, redCanvas.triple.accent, redCanvas.triple.dark), null);
        tryCompare(greenCanvas, "ready", true, 5000);
        compare(Tint.hyprlandBorderCommands(null, greenCanvas.triple.accent, greenCanvas.triple.dark), null);
        tryCompare(blueCanvas, "ready", true, 5000);
        compare(Tint.hyprlandBorderCommands(null, blueCanvas.triple.accent, blueCanvas.triple.dark), null);
    }
}
