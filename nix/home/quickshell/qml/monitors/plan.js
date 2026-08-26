// Monitor planning: hyprctl monitors -j -> rule match -> horizontal layout ->
// forced overrides -> one hl.monitor({...}) Lua expression per output.
//
// Ported from rust/hyprmon's spec.rs/matcher.rs/plan.rs/overrides.rs so the
// planner is unit-testable under QtTest while the crate still owns applying
// it (see docs/superpowers/plans/2026-08-26-qs-migration-2a-monitor-logic.md).
// The crate's render() emits `hyprctl keyword monitor ...`, kept there only
// for its own tests/logging; render() here is spec.rs's render_lua()
// instead, because that legacy keyword is the one Hyprland 0.55+ silently
// no-ops under the Lua parser (rust/hyprmon/src/runner.rs) — the live path
// this port has to match is `hyprctl eval 'hl.monitor({...})'`.
.pragma library

// hyprctl monitors -j field names are already camelCase, so most of these
// pass straight through; refreshRate is renamed to refresh for parity with
// the rule/override vocabulary (which never says "rate"). description and
// availableModes are carried even though the plan doc's shape omits them:
// matcher.rs matches on description (matchRule below) and plan.rs's refresh
// rounding reads availableModes, so dropping either here would silently
// break both once they're wired in.
function parseMonitors(json) {
    const raw = JSON.parse(json);
    if (!Array.isArray(raw))
        throw new Error("parse monitors -j: expected an array");
    return raw.map(m => ({
        name: m.name,
        description: m.description || "",
        make: m.make || "",
        model: m.model || "",
        serial: m.serial || "",
        width: m.width,
        height: m.height,
        refresh: m.refreshRate || 0,
        availableModes: m.availableModes || []
    }));
}

// One rule's match_name/match_description compiled: rust/hyprmon's
// CompiledRule.new, where a present-but-unparseable regex is kept apart from
// an absent one so the former can still fail to match rather than being
// silently treated as "no constraint".
function compileField(pattern) {
    if (pattern === undefined || pattern === null)
        return { present: false, regex: null };
    try {
        return { present: true, regex: new RegExp(pattern) };
    } catch (e) {
        return { present: true, regex: null };
    }
}

function fieldMatches(compiled, value) {
    if (compiled.regex)
        return compiled.regex.test(value);
    // present but failed to compile -> never matches; absent -> unconstrained.
    return !compiled.present;
}

function ruleMatches(rule, monitor) {
    const name = fieldMatches(compileField(rule.matchName), monitor.name);
    const description = fieldMatches(compileField(rule.matchDescription), monitor.description);
    return name && description;
}

// The single-monitor slice of matcher.rs's match_monitors: first rule in
// list order whose name/description regexes (each optional, both must hold
// when present) match, or null if none does. match_monitors additionally
// drops non-matching monitors from its output list; planFor below does that
// part by simply skipping a null result per monitor.
function matchRule(monitor, rules) {
    const list = (rules && rules.rules) || [];
    for (const rule of list) {
        if (ruleMatches(rule, monitor))
            return rule;
    }
    return null;
}
