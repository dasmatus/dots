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
}
