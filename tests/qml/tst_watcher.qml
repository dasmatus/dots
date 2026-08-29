// Proves Watcher.qml's own wiring is reachable, not just that plan.js's
// functions work in isolation — the gap plan 1b left (four tint writers
// ported and unit-tested, three never wired to anything that called them).
// commandsForState is the exact function Watcher.qml's `hyprctl monitors -j`
// stdout handler calls; this drives it with fixture JSON standing in for
// that stdout and asserts on the literal argv it would hand to Process,
// with no live compositor, FileView or Process anywhere near the test.
import QtQuick
import QtTest
import "../../nix/home/quickshell/qml/monitors/watch.js" as Watch

TestCase {
    name: "Watcher"

    function monitorsJsonOne() {
        return JSON.stringify([
            {
                id: 0,
                name: "DP-1",
                description: "Ancor Communications ASUS VG279QM 0x00012345",
                width: 1920,
                height: 1080,
                refreshRate: 239.76,
                availableModes: ["1920x1080@239.76Hz", "1920x1080@60.00Hz"]
            }
        ]);
    }

    function rulesOne() {
        return {
            rules: [
                {
                    name: "primary-240hz",
                    matchName: "^DP-1$",
                    resolution: "1920x1080@240",
                    scale: 1.0,
                    vrr: "left"
                }
            ]
        };
    }

    function test_commandsForState_invokes_the_planner_and_the_applier() {
        const commands = Watch.commandsForState(monitorsJsonOne(), rulesOne(), { entries: [] });

        compare(commands.length, 1);
        compare(commands[0].name, "DP-1");
        compare(commands[0].argv, ["hyprctl", "eval", "hl.monitor({output=\"DP-1\", mode=\"1920x1080@240\", position=\"0x0\", scale=1, vrr=1})"]);
    }

    // An unmatched monitor list is the planner's own no-op case (matcher.rs's
    // "disabled output" behaviour, ported in plan.js's planFor) — proved
    // here too so a caller cannot mistake "no rules matched" for "the wiring
    // is broken".
    function test_commandsForState_is_empty_when_nothing_matches() {
        const commands = Watch.commandsForState(monitorsJsonOne(), { rules: [] }, { entries: [] });

        compare(commands.length, 0);
    }

    // An override changes the rendered command, not just the planned spec —
    // proof this chain runs applyOverrides too, not only matchRule/plan.
    function test_commandsForState_applies_overrides_before_rendering() {
        const overrides = { entries: [{ name: "DP-1", position: "1920x0" }] };
        const commands = Watch.commandsForState(monitorsJsonOne(), rulesOne(), overrides);

        compare(commands.length, 1);
        verify(commands[0].argv[2].indexOf("position=\"1920x0\"") !== -1, "expected the override's position in the rendered command, got " + commands[0].argv[2]);
    }

    // Reachability test, tst_tint_wiring.qml's own readSource-plus-indexOf
    // idiom: qmltestrunner cannot instantiate Watcher.qml — it reaches
    // Quickshell.Io's FileView/Process, whose plugin is linked into the
    // quickshell binary rather than loadable standalone — so the adapter
    // wiring `rules`/`overrides` depend on has no live test; this reads the
    // shipped source instead. Motivating bug: both used to read a bare
    // `root` off their adapter, which does not exist anywhere on Quickshell
    // 0.3.0's JsonAdapter (confirmed against quickshell-io.qmltypes), so
    // `rules`/`overrides` were silently the empty fallback forever and no
    // `hl.monitor` call was ever made.
    function readSource(relPath) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl(relPath), false);
        xhr.send();
        compare(xhr.status, 200, relPath + " must be readable (needs QML_XHR_ALLOW_FILE_READ=1)");
        return xhr.responseText;
    }

    // Slices out each `JsonAdapter { ... }` body in source order, the same
    // scoping tst_tint_wiring.qml's applyAccentBody() uses on a function
    // body and for the same reason: `rulesFile`'s adapter and root.rules
    // both happen to be named `rules`, so an unscoped
    // `indexOf("property var rules")` is satisfied by the OUTER
    // `readonly property var rules: ...` line even when the adapter itself
    // never declares anything — exactly the pre-fix shape, where the block
    // was a bare `JsonAdapter {}`. Only a check confined to the block body
    // can tell "the adapter declares it" from "some other line nearby
    // happens to contain the same words".
    function jsonAdapterBlocks(source) {
        const marker = "JsonAdapter {";
        const blocks = [];
        let searchFrom = 0;

        while (true) {
            const start = source.indexOf(marker, searchFrom);
            if (start === -1)
                break;

            let depth = 0;
            let end = -1;
            for (let i = start + marker.length - 1; i < source.length; i++) {
                if (source[i] === "{")
                    depth++;
                else if (source[i] === "}") {
                    depth--;
                    if (depth === 0) {
                        end = i;
                        break;
                    }
                }
            }
            verify(end !== -1, "JsonAdapter block starting at " + start + " must have a matching closing brace");

            blocks.push(source.slice(start, end + 1));
            searchFrom = end + 1;
        }

        return blocks;
    }

    function test_watcher_never_reads_the_nonexistent_adapter_root() {
        const watcher = readSource("../../nix/home/quickshell/qml/monitors/Watcher.qml");
        verify(watcher.indexOf(".adapter.root") === -1, "JsonAdapter has no `root` property on this Quickshell build — reading a bare root off it is silently always undefined");
    }

    function test_watcher_declares_a_property_for_each_adapter_to_populate() {
        const watcher = readSource("../../nix/home/quickshell/qml/monitors/Watcher.qml");
        const blocks = jsonAdapterBlocks(watcher);

        compare(blocks.length, 2, "rulesFile and overridesFile must each declare their own JsonAdapter { ... }");
        verify(blocks[0].indexOf("property var rules") !== -1, "rulesFile's own JsonAdapter block needs a declared `rules` property — JsonAdapter only populates a property declared on the adapter instance itself");
        verify(blocks[1].indexOf("property var entries") !== -1, "overridesFile's own JsonAdapter block needs a declared `entries` property — JsonAdapter only populates a property declared on the adapter instance itself");
    }

    // planFor()/applyOverrides() (plan.js) take { rules: [...] } / {
    // entries: [...] }, never a bare array — plan.js's own matchRule does
    // `(rules && rules.rules) || []`. A "simplification" to
    // `readonly property var rules: rulesFile.adapter.rules` (dropping the
    // wrapper) would satisfy both tests above AND keep reading real data
    // off the adapter, yet silently restore the exact bug this task fixed:
    // `rules.rules` on a bare array is undefined, matchRule falls back to
    // `[]`, and no `hl.monitor` call is ever made again. This is the
    // assertion that would have caught the original defect, so it is the
    // one guarding against its return.
    function test_watcher_rewraps_the_adapter_reads_into_the_shape_planFor_expects() {
        const watcher = readSource("../../nix/home/quickshell/qml/monitors/Watcher.qml");
        verify(watcher.indexOf("({ rules: rulesFile.adapter.rules })") !== -1, "root.rules must rewrap rulesFile.adapter.rules as { rules: [...] } — planFor() reads rules.rules, not a bare array");
        verify(watcher.indexOf("({ entries: overridesFile.adapter.entries })") !== -1, "root.overrides must rewrap overridesFile.adapter.entries as { entries: [...] } — applyOverrides() reads overrides.entries, not a bare array");
    }
}
