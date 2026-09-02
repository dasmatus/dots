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

// commandsForState's own guard: `hyprctl monitors -j` can race Hyprland's
// IPC socket coming up (empty stdout), get killed mid-write (a truncated
// read), or — in principle — print valid JSON that is not an array. All of
// those are "the process gave me nothing usable", which Plan.parseMonitors
// deliberately does NOT shrug off (its contract is "parse this JSON", and
// tst_monitors.qml's test_parseMonitors_rejects_garbage pins it throwing on
// exactly this input) — a pure JSON parser silently returning "zero
// monitors" for garbage would make it indistinguishable from a legitimate
// empty reading. That distinction still matters to whoever calls
// commandsForState, so it is preserved here rather than flattened: `ok:
// false` means "this read did not happen, try again"; `ok: true` with an
// empty commands list means "it happened, and nothing matched" — Watcher.qml
// uses exactly that difference to decide whether to retry.
function attemptCommandsForState(monitorsJson, rules, overrides) {
    try {
        return { ok: true, commands: commandsForState(monitorsJson, rules, overrides) };
    } catch (e) {
        return { ok: false, commands: [] };
    }
}
