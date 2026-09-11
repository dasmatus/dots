// Monitor planning: hyprctl monitors -j -> rule match -> horizontal layout ->
// forced overrides -> one hl.monitor({...}) Lua expression per output.
//
// Ported from rust/hyprmon's spec.rs/matcher.rs/plan.rs/overrides.rs so the
// planner is unit-testable under QtTest while the crate still owns applying
// it (see docs/superpowers/plans/2026-08-26-qs-migration-2a-monitor-logic.md).
// The crate's render() emits `hyprctl keyword monitor ...`, kept there only
// for its own tests/logging; render() here is spec.rs's render_lua()
// instead, because that legacy keyword is the one Hyprland 0.55+ silently
// no-ops under the Lua parser (rust/hyprmon/src/runner.rs). The live path
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
// when present) match, or null if none does. match_monitors also
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

// Rust's str::split_once: the substring before/after the FIRST occurrence of
// sep, or null when sep never appears. JS's String.split has no one-split
// form, and a naive split('x').length===2 check would disagree with Rust on
// a string with more than one 'x' (e.g. a stray "1920x1080x60" mode); this
// takes the same first slice Rust's split_once does either way.
function splitOnce(s, sep) {
    const i = s.indexOf(sep);
    if (i === -1)
        return null;
    return [s.slice(0, i), s.slice(i + sep.length)];
}

// Rust's u32::from_str: digits only, no sign, no decimal point, no
// whitespace. Number("") is 0 and Number(" 5") is 5 in JS, both of which
// Rust's parser rejects, so this checks the string shape before converting
// rather than trusting Number()'s laxer parse.
function parseU32(s) {
    if (!/^\d+$/.test(s))
        return null;
    return Number(s);
}

// Rust's i64::from_str, signed counterpart of parseU32 (positions can be
// negative when a monitor sits above/left of the origin).
function parseI64(s) {
    if (!/^-?\d+$/.test(s))
        return null;
    return Number(s);
}

// Rust's f64::from_str: a plain decimal (optionally signed/exponent), never
// something like "60.00Hz", which matters because that IS the shape real
// hyprctl reports in availableModes (see maxRefreshAt below); a lax
// parseFloat would silently accept the "Hz" suffix's leading digits.
function parseFloatStrict(s) {
    if (!/^-?\d+(\.\d+)?([eE][-+]?\d+)?$/.test(s))
        return null;
    return Number(s);
}

// `1920x1080` -> [1920, 1080]; `1920x1080@240` -> [1920, 1080] (refresh
// stripped first). null for anything that isn't WxH[@R] with integer W/H.
function parseWxH(s) {
    const base = splitOnce(s, "@");
    const wh = base ? base[0] : s;
    const parts = splitOnce(wh, "x");
    if (!parts)
        return null;
    const w = parseU32(parts[0]);
    const h = parseU32(parts[1]);
    if (w === null || h === null)
        return null;
    return [w, h];
}

// `0x0` -> [0, 0]; `1920x0` -> [1920, 0]. null for malformed positions.
function parsePosition(s) {
    const parts = splitOnce(s, "x");
    if (!parts)
        return null;
    const x = parseI64(parts[0]);
    const y = parseI64(parts[1]);
    if (x === null || y === null)
        return null;
    return [x, y];
}

// hyprctl's own availableModes entries spell the rate `RR.RRHz` (e.g.
// `60.00Hz`), never the bare `RR` the rule/override vocabulary and the
// fixtures ported from rust/hyprmon's tests use. Stripped here, and only
// here: rule-authored resolutions (effectiveResolutionString's `@rate`
// parsing) never carry this suffix, so treating it as part of the general
// float grammar would silently accept malformed rule input instead of
// leaving it for Hyprland to reject.
function stripHzSuffix(s) {
    return s.replace(/Hz$/i, "");
}

// `1920x1080@239.76` -> [1920, 1080, 239.76]; `1920x1080@60.00Hz` (the shape
// hyprctl actually emits) -> [1920, 1080, 60]. null for a mode entry this
// doesn't model.
function parseMode(s) {
    const whRate = splitOnce(s, "@");
    if (!whRate)
        return null;
    const parts = splitOnce(whRate[0], "x");
    if (!parts)
        return null;
    const w = parseU32(parts[0]);
    const h = parseU32(parts[1]);
    const rate = parseFloatStrict(stripHzSuffix(whRate[1]));
    if (w === null || h === null || rate === null)
        return null;
    return [w, h, rate];
}

// Round a refresh rate up to the next integer Hz. Monitors advertise
// fractional rates (59.95, 119.98, 239.76) that Hyprland honours literally,
// producing a sub-integer clock; ceiling snaps to the intended 60/120/240.
function roundUpRefresh(r) {
    return Math.ceil(r);
}

// Highest refresh the monitor advertises for resolution w×h, read from
// availableModes entries of the form WxH@R (parseMode strips a trailing Hz
// first, so this matches real hyprctl output, not just hand-built
// fixtures). null when no mode matches at that resolution, the case
// refreshFor's live-refresh fallback below exists for.
function maxRefreshAt(modes, w, h) {
    let best = null;
    for (const mode of modes) {
        const parsed = parseMode(mode);
        if (!parsed)
            continue;
        const [mw, mh, rate] = parsed;
        if (mw === w && mh === h && (best === null || rate > best))
            best = rate;
    }
    return best;
}

// Refresh rate (integer Hz, rounded up) to append to a WxH or preferred
// resolution: the highest rate the monitor advertises for that resolution,
// falling back to the live refresh when no mode matches. The fallback is the
// NVIDIA workaround: the proprietary driver doesn't populate availableModes
// over wlr-output-management the way KMS drivers do, so without it a rule
// like `2560x1200` (no explicit refresh) would land on Hyprland's fractional
// default (e.g. 59.95 Hz) instead of the intended 60.
function refreshFor(monitor, w, h) {
    const max = maxRefreshAt(monitor.availableModes || [], w, h);
    if (max !== null)
        return roundUpRefresh(max);
    if (monitor.refresh > 0)
        return roundUpRefresh(monitor.refresh);
    return null;
}

// `preferred` with the max supported refresh (rounded up) as `@R`, or bare
// `preferred` when no rate can be determined.
function preferredWithRefresh(m) {
    const rate = refreshFor(m.monitor, m.monitor.width, m.monitor.height);
    return rate !== null ? `preferred@${rate}` : "preferred";
}

// Resolve the pixel size used for layout math: the rule's resolution (when
// it parses as WxH) wins; otherwise the monitor's live width/height.
function effectiveResolution(m) {
    if (m.rule.resolution) {
        const parsed = parseWxH(m.rule.resolution);
        if (parsed)
            return parsed;
    }
    return [m.monitor.width, m.monitor.height];
}

// Render the spec's resolution field. No rule resolution -> `preferred`; a
// rule with `WxH` -> `WxH@R` with R the highest advertised refresh for that
// resolution (rounded up); a rule with `WxH@R` honours the authored
// resolution but rounds R up to an integer.
function effectiveResolutionString(m, w, h) {
    const resolution = m.rule.resolution;
    let base;
    if (resolution && resolution.indexOf("@") !== -1) {
        const parts = splitOnce(resolution, "@");
        const rate = parseFloatStrict(parts[1]);
        base = rate !== null && rate > 0 ? `${parts[0]}@${roundUpRefresh(rate)}` : resolution;
    } else if (resolution) {
        const parsed = parseWxH(resolution);
        if (parsed) {
            const rate = refreshFor(m.monitor, parsed[0], parsed[1]);
            base = rate !== null ? `${resolution}@${rate}` : resolution;
        } else {
            base = preferredWithRefresh(m);
        }
    } else {
        base = preferredWithRefresh(m);
    }
    return base.replace("__W__", String(w)).replace("__H__", String(h));
}

// `1.0` -> `"1"`, `1.5` -> `"1.5"`, `2.0` -> `"2"`. Matches the integer-
// without-trailing-zero style used in hand-written Hyprland configs.
function renderScale(s) {
    return s % 1 === 0 ? String(Math.trunc(s)) : String(s);
}

// The token the vrr enum ("off"/"left"/"right"/"auto", the lowercase form
// rules.json and overrides.json actually spell it) renders as, or null for
// "off". Hyprland's Lua vrr field takes 0/1/2/3, and 0 (off) is the
// implicit default, so it's never emitted as an explicit field either.
function vrrToken(vrr) {
    switch (vrr) {
    case "left":
        return "vrrleft";
    case "right":
        return "vrrright";
    case "auto":
        return "vrrauto";
    default:
        return null;
    }
}

// The rule's vrr is authoritative: "off" always yields no token, even if the
// monitor itself already reports vrr on from a prior manual change, so
// re-running the planner can turn it back off.
function effectiveVrr(m) {
    return vrrToken(m.rule.vrr || "off");
}

// Plan a horizontal layout for the matched (monitor, rule) pairs, in the
// same order as matched. A rule with an explicit position pins that monitor
// absolutely and resets the running x-cursor to its right edge, so a later
// rule with no position continues from there; a rule with no position is
// placed at the current cursor, y=0. Mirrors how a hand-written chain of
// `monitor=` lines behaves.
function layoutMatched(matched) {
    const specs = [];
    let x = 0;
    for (const m of matched) {
        const [w, h] = effectiveResolution(m);
        const pos = m.rule.position != null ? m.rule.position : `${x}x0`;
        const parsed = parsePosition(pos);
        x = parsed ? parsed[0] + w : x + w;
        specs.push({
            name: m.monitor.name,
            resolution: effectiveResolutionString(m, w, h),
            position: pos,
            scale: renderScale(m.rule.scale),
            transform: m.rule.transform != null ? m.rule.transform : null,
            vrr: effectiveVrr(m)
        });
    }
    return specs;
}

// Match every monitor against rules, plan the survivors into a horizontal
// layout, apply overrides last, and return the resulting specs. Unmatched
// monitors are silently dropped (matcher.rs's match_monitors behaviour)
// rather than emitted as "disabled": an empty result is a no-op for the
// caller, not a command to switch anything off. overrides is optional so
// Task 2's rows (which never touch it) still pass unmodified.
function planFor(monitors, rules, overrides) {
    const matched = [];
    for (const monitor of monitors) {
        const rule = matchRule(monitor, rules);
        if (rule)
            matched.push({ monitor: monitor, rule: rule });
    }
    const specs = layoutMatched(matched);
    return overrides ? applyOverrides(specs, monitors, overrides) : specs;
}

// Find the override entry that applies to monitor, or null. Name pins take
// priority over description fallbacks; within each pass the first matching
// entry in list order wins, overrides.rs's match_override.
function matchOverride(monitor, overrides) {
    const entries = (overrides && overrides.entries) || [];
    const byName = entries.find(e => e.name === monitor.name);
    if (byName)
        return byName;
    const byDescription = entries.find(e => (e.name === undefined || e.name === null) && e.description === monitor.description);
    return byDescription || null;
}

// Apply overrides to a planned set of specs. For each spec, the matching
// override entry (looked up via the original monitor list, since the spec
// carries the name but not the description the fallback match needs)
// replaces whichever fields it sets; everything else falls through
// unchanged. A field set to a falsy-but-meaningful value (transform 0, an
// explicit vrr "off") must still apply, so every check below is
// undefined/null-aware rather than a truthiness test.
function applyOverrides(specs, monitors, overrides) {
    return specs.map(spec => {
        const monitor = monitors.find(m => m.name === spec.name);
        if (!monitor)
            return spec;
        const entry = matchOverride(monitor, overrides);
        if (!entry)
            return spec;
        const out = Object.assign({}, spec);
        if (entry.resolution != null)
            out.resolution = entry.resolution;
        if (entry.position != null)
            out.position = entry.position;
        if (entry.scale != null)
            out.scale = renderScale(entry.scale);
        if (entry.transform != null)
            out.transform = entry.transform;
        if (entry.vrr != null)
            out.vrr = vrrToken(entry.vrr);
        return out;
    });
}

function luaString(s) {
    // Escape backslashes and double quotes, then wrap in double quotes.
    const escaped = s.replace(/\\/g, "\\\\").replace(/"/g, "\\\"");
    return `"${escaped}"`;
}

function luaNumber(s) {
    // Accepts strings like "1" or "1.5"; invalid input falls back to itself
    // so Hyprland errors visibly instead of silently ignoring the value.
    const n = Number(s);
    return Number.isNaN(n) ? s : String(n);
}

// Render a spec as the Lua table argument to `hyprctl eval 'hl.monitor({...})'`.
// See this file's header for why this is the only render the port keeps.
function render(spec) {
    const fields = [
        `output=${luaString(spec.name)}`,
        `mode=${luaString(spec.resolution)}`,
        `position=${luaString(spec.position)}`,
        `scale=${luaNumber(spec.scale)}`
    ];
    if (spec.transform != null)
        fields.push(`transform=${spec.transform}`);
    if (spec.vrr) {
        const token = { vrrleft: 1, vrrright: 2, vrrauto: 3 }[spec.vrr] || 0;
        fields.push(`vrr=${token}`);
    }
    return `hl.monitor({${fields.join(", ")}})`;
}
