// Watcher.qml's own contribution on top of plan.js's parse/plan/render:
// the parse -> plan -> render -> argv chain, kept in a plain .pragma
// library so tests/qml/tst_watcher.qml can call it with fixture JSON and
// assert on the exact hyprctl argv it produces, with no live Hyprland
// socket, FileView or Process anywhere near the test run.
//
// This is what proves the watcher's OWN wiring is reachable, not just that
// plan.js's functions work in isolation — the gap plan 1b left (four tint
// writers ported and unit-tested, three never wired to anything that called
// them) is exactly what a test that only re-exercised plan.js's own
// functions would have missed here too.
.pragma library
.import "plan.js" as Plan

function commandsForState(monitorsJson, rules, overrides) {
    const monitors = Plan.parseMonitors(monitorsJson);
    const specs = Plan.planFor(monitors, rules, overrides);
    return specs.map(spec => ({
        name: spec.name,
        argv: ["hyprctl", "eval", Plan.render(spec)]
    }));
}
