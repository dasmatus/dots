// Monitor plan: parse, match, layout, override, render.
//
// Fixtures mirror rust/hyprmon/tests/common/mod.rs's monitor_240hz/
// monitor_60hz/rules_two — the same 27" 1080p 240Hz VRR panel and 25" 1200p
// 60Hz panel the Rust suite plans against, so a row that fails here would
// have failed the same way in cargo test.
import QtQuick
import QtTest
import "../../nix/home/quickshell/qml/monitors/plan.js" as Plan

TestCase {
    name: "Monitors"

    function monitor240hz() {
        return {
            name: "DP-1",
            description: "Ancor Communications ASUS VG279QM 0x00012345",
            make: "Ancor Communications",
            model: "ASUS VG279QM",
            serial: "0x00012345",
            width: 1920,
            height: 1080,
            refresh: 239.76,
            availableModes: ["1920x1080@239.76", "1920x1080@60"]
        };
    }

    function monitor60hz() {
        return {
            name: "HDMI-A-1",
            description: "Goldstar Company Ltd 25UM58 0x00067890",
            make: "Goldstar Company Ltd",
            model: "25UM58",
            serial: "0x00067890",
            width: 2560,
            height: 1200,
            refresh: 59.95,
            availableModes: ["2560x1200@59.95"]
        };
    }

    // The hyprctl monitors -j payload for the two fixtures above, in the
    // camelCase field names hyprctl actually emits.
    function monitorsJsonTwo() {
        return JSON.stringify([
            {
                id: 0,
                name: "DP-1",
                description: "Ancor Communications ASUS VG279QM 0x00012345",
                width: 1920,
                height: 1080,
                refreshRate: 239.76,
                make: "Ancor Communications",
                model: "ASUS VG279QM",
                serial: "0x00012345",
                transform: 0,
                vrr: true,
                availableModes: ["1920x1080@239.76", "1920x1080@60"]
            },
            {
                id: 1,
                name: "HDMI-A-1",
                description: "Goldstar Company Ltd 25UM58 0x00067890",
                width: 2560,
                height: 1200,
                refreshRate: 59.95,
                make: "Goldstar Company Ltd",
                model: "25UM58",
                serial: "0x00067890",
                transform: 0,
                vrr: false,
                availableModes: ["2560x1200@59.95"]
            }
        ]);
    }

    // rules_two: 240Hz VRR on the left, 60Hz on the right, plus a fallback
    // for unknown monitors (e.g. a hotplugged projector).
    function rulesTwo() {
        return {
            rules: [
                {
                    name: "primary-240hz",
                    matchName: "^DP-1$",
                    matchDescription: "VG279QM",
                    resolution: "1920x1080@240",
                    scale: 1.0,
                    vrr: "left"
                },
                {
                    name: "secondary-60hz",
                    matchName: "^HDMI-A-1$",
                    matchDescription: "25UM58",
                    resolution: "2560x1200",
                    scale: 1.0,
                    vrr: "off"
                },
                {
                    name: "*",
                    scale: 1.0,
                    vrr: "off"
                }
            ]
        };
    }

    function test_parseMonitors_parses_two_monitor_payload() {
        const parsed = Plan.parseMonitors(monitorsJsonTwo());
        compare(parsed.length, 2);
        compare(parsed[0].name, "DP-1");
        compare(parsed[0].description, monitor240hz().description);
        compare(parsed[0].make, "Ancor Communications");
        compare(parsed[0].model, "ASUS VG279QM");
        compare(parsed[0].serial, "0x00012345");
        compare(parsed[0].width, 1920);
        compare(parsed[0].height, 1080);
        compare(parsed[0].refresh, 239.76);
        compare(parsed[0].availableModes, ["1920x1080@239.76", "1920x1080@60"]);
        compare(parsed[1].name, "HDMI-A-1");
    }

    function test_parseMonitors_rejects_garbage() {
        let threw = false;
        try {
            Plan.parseMonitors("not json");
        } catch (e) {
            threw = true;
        }
        verify(threw, "garbage JSON must throw rather than return something");
    }

    // rust/hyprmon/tests/matcher.rs, ported one row per test: matchRule is
    // the single-monitor slice of matcher.rs's match_monitors — same
    // first-match-wins precedence, same present-but-invalid-regex-never-
    // matches safety net.
    function test_matchRule_data() {
        return [
            {
                tag: "matches the primary by name and description",
                monitor: monitor240hz(),
                rules: rulesTwo(),
                expectedRuleName: "primary-240hz"
            },
            {
                tag: "matches the secondary by name and description",
                monitor: monitor60hz(),
                rules: rulesTwo(),
                expectedRuleName: "secondary-60hz"
            },
            {
                tag: "fallback catches an unknown monitor",
                monitor: {
                    name: "DP-3",
                    description: "Some Projector",
                    width: 1920,
                    height: 1080,
                    refresh: 60,
                    availableModes: []
                },
                rules: rulesTwo(),
                expectedRuleName: "*"
            },
            {
                tag: "first match wins over a looser later rule",
                monitor: monitor240hz(),
                rules: {
                    rules: [
                        { name: "specific", matchName: "^DP-1$", resolution: "1920x1080@240", scale: 1.0, vrr: "left" },
                        { name: "loose", matchName: "^DP-", scale: 1.0, vrr: "off" }
                    ]
                },
                expectedRuleName: "specific"
            },
            {
                tag: "a present but invalid regex never matches",
                monitor: monitor240hz(),
                rules: { rules: [{ name: "broken", matchName: "(", scale: 1.0, vrr: "off" }] },
                expectedRuleName: null
            },
            {
                tag: "empty rules match nothing",
                monitor: monitor240hz(),
                rules: { rules: [] },
                expectedRuleName: null
            },
            {
                tag: "a description-only rule matches on description",
                monitor: monitor240hz(),
                rules: { rules: [{ name: "by-desc", matchDescription: "VG279QM", scale: 1.0, vrr: "off" }] },
                expectedRuleName: "by-desc"
            }
        ];
    }

    function test_matchRule(row) {
        const rule = Plan.matchRule(row.monitor, row.rules);
        if (row.expectedRuleName === null) {
            verify(rule === null, "expected no match, got " + JSON.stringify(rule));
        } else {
            verify(rule !== null, "expected a match");
            compare(rule.name, row.expectedRuleName);
        }
    }

    // rulesTwo() with one in-place edit, so each planFor row can flex a
    // single rule field the way rust/hyprmon/tests/plan.rs mutates
    // rules_two() in place, without every row hand-building a whole ruleset.
    function rulesTwoWith(mutate) {
        const rules = rulesTwo();
        mutate(rules);
        return rules;
    }

    // rust/hyprmon/tests/plan.rs, ported one row per test. planFor fuses
    // matcher.rs's match_monitors with plan.rs's plan(): unmatched monitors
    // are dropped before layout, same as the Rust pipeline.
    function test_planFor_data() {
        return [
            {
                tag: "plans two monitors left to right",
                monitors: [monitor240hz(), monitor60hz()],
                rules: rulesTwo(),
                expected: [
                    { name: "DP-1", position: "0x0", resolution: "1920x1080@240", vrr: "vrrleft" },
                    { name: "HDMI-A-1", position: "1920x0", resolution: "2560x1200@60", vrr: null }
                ]
            },
            {
                // The disabled-output case: a monitor with no matching rule
                // (here, simply no monitors at all) gets no MonitorSpec, so
                // hyprmon emits no hl.monitor call for it and Hyprland's own
                // auto-detect is left in place rather than the output being
                // switched off — the property rust/hyprmon/src/runner.rs's
                // apply_with documents. Ported from
                // empty_match_yields_empty_plan.
                tag: "disabled output: no matches yields an empty plan",
                monitors: [],
                rules: rulesTwo(),
                expected: []
            },
            {
                tag: "an explicit position pins and advances the cursor",
                monitors: [monitor240hz(), monitor60hz(), monitor240hz()],
                rules: rulesTwoWith(r => {
                    r.rules[1].position = "3840x0";
                }),
                expected: [
                    { position: "0x0" },
                    { position: "3840x0" },
                    { position: "6400x0" }
                ]
            },
            {
                tag: "fractional scale renders with a dot",
                monitors: [monitor240hz()],
                rules: rulesTwoWith(r => {
                    r.rules[0].scale = 1.5;
                }),
                expected: [{ scale: "1.5" }]
            },
            {
                tag: "integral scale drops the trailing zero",
                monitors: [monitor240hz()],
                rules: rulesTwoWith(r => {
                    r.rules[0].scale = 2.0;
                }),
                expected: [{ scale: "2" }]
            },
            {
                tag: "fallback rule emits preferred with the max advertised refresh",
                monitors: [Object.assign(monitor240hz(), { name: "DP-9", description: "Mystery Panel" })],
                rules: rulesTwo(),
                expected: [{ resolution: "preferred@240" }]
            },
            {
                // NVIDIA's proprietary driver doesn't populate availableModes,
                // so a rule pinning WxH with no refresh must fall back to the
                // live refreshRate (rounded up) instead of a bare resolution
                // Hyprland would default to 59.95 Hz.
                tag: "nvidia empty modes falls back to the live refresh, rounded up",
                monitors: [Object.assign(monitor60hz(), { availableModes: [] })],
                rules: rulesTwo(),
                expected: [{ name: "HDMI-A-1", resolution: "2560x1200@60" }]
            },
            {
                // The bug 2b fixes: real hyprctl spells every availableModes
                // entry "WxH@RR.RRHz", not the bare "WxH@RR" every other row
                // in this file uses. A monitor whose live refreshRate is
                // stale (still reporting last session's 59.95) but whose
                // 2560x1200 mode is actually capable of 143.86 must be raised
                // to that mode's ceiling — 144 — not stuck at ceil(59.95)=60,
                // which is what maxRefreshAt returned before the Hz suffix
                // was stripped (see refreshFor's docstring).
                tag: "a real hyprctl Hz-suffixed mode is parsed and raises the monitor to its top rate",
                monitors: [Object.assign(monitor60hz(), {
                    refresh: 59.95,
                    availableModes: ["2560x1200@143.86Hz", "2560x1200@59.95Hz"]
                })],
                rules: rulesTwo(),
                expected: [{ name: "HDMI-A-1", resolution: "2560x1200@144" }]
            },
            {
                tag: "nvidia empty modes on the preferred path falls back too",
                monitors: [Object.assign(monitor60hz(), { availableModes: [], name: "DP-9", description: "NVIDIA HDMI sink" })],
                rules: rulesTwo(),
                expected: [{ resolution: "preferred@60" }]
            },
            {
                tag: "transform is carried onto the spec when the rule sets one",
                monitors: [monitor240hz()],
                rules: rulesTwoWith(r => {
                    r.rules[0].transform = 2;
                }),
                expected: [{ transform: 2 }]
            },
            {
                tag: "vrr off emits no token",
                monitors: [monitor240hz()],
                rules: rulesTwoWith(r => {
                    r.rules[0].vrr = "off";
                }),
                expected: [{ vrr: null }]
            }
        ];
    }

    function test_planFor(row) {
        const specs = Plan.planFor(row.monitors, row.rules);
        compare(specs.length, row.expected.length);
        for (let i = 0; i < row.expected.length; i++) {
            const want = row.expected[i];
            for (const key in want)
                compare(specs[i][key], want[key]);
        }
    }

    // rust/hyprmon/tests/spec.rs's render_lua_* tests, plus the transform
    // case plan.rs's transform_is_emitted_when_set checks through render().
    // render() here IS render_lua(): the crate's own render() (the legacy
    // `hyprctl keyword monitor ...` CSV) has no port, because Hyprland 0.55+
    // no-ops that IPC under the Lua parser — see plan.js's file header.
    function test_render_data() {
        return [
            {
                tag: "emits the hl.monitor call with vrr",
                spec: { name: "DP-1", resolution: "1920x1080@240", position: "0x0", scale: "1", transform: null, vrr: "vrrleft" },
                expected: "hl.monitor({output=\"DP-1\", mode=\"1920x1080@240\", position=\"0x0\", scale=1, vrr=1})"
            },
            {
                tag: "omits transform and vrr when unset",
                spec: { name: "HDMI-A-1", resolution: "2560x1200", position: "1920x0", scale: "1.5", transform: null, vrr: null },
                expected: "hl.monitor({output=\"HDMI-A-1\", mode=\"2560x1200\", position=\"1920x0\", scale=1.5})"
            },
            {
                tag: "escapes double quotes in the output name",
                spec: { name: "DP-\"1", resolution: "preferred", position: "0x0", scale: "1", transform: null, vrr: null },
                expected: "hl.monitor({output=\"DP-\\\"1\", mode=\"preferred\", position=\"0x0\", scale=1})"
            },
            {
                tag: "emits transform alongside vrr",
                spec: { name: "DP-1", resolution: "1920x1080@240", position: "0x0", scale: "1", transform: 2, vrr: "vrrleft" },
                expected: "hl.monitor({output=\"DP-1\", mode=\"1920x1080@240\", position=\"0x0\", scale=1, transform=2, vrr=1})"
            }
        ];
    }

    function test_render(row) {
        compare(Plan.render(row.spec), row.expected);
    }

    // A bare planned spec, the shape layoutMatched would have produced
    // before overrides run — mirrors rust/hyprmon/tests/overrides.rs's own
    // spec() helper.
    function specFor(name, resolution, position, scale) {
        return { name: name, resolution: resolution, position: position, scale: scale, transform: null, vrr: null };
    }

    // rust/hyprmon/tests/overrides.rs's matching cases. Load/save round-trip
    // and upsert/remove aren't ported: those manage overrides.json on disk,
    // which is 2b's FileView surface, not this pure-logic module.
    function test_matchOverride_data() {
        return [
            {
                tag: "a name pin wins over a description-only entry",
                monitor: monitor60hz(),
                overrides: {
                    entries: [
                        { name: "HDMI-A-1", resolution: "2560x1200@60" },
                        { description: monitor60hz().description, resolution: "1600x1200@60" }
                    ]
                },
                expectedResolution: "2560x1200@60"
            },
            {
                tag: "description fallback matches when no name pin exists",
                monitor: monitor60hz(),
                overrides: { entries: [{ description: monitor60hz().description, resolution: "2560x1200@60" }] },
                expectedResolution: "2560x1200@60"
            },
            {
                tag: "no match returns null",
                monitor: monitor60hz(),
                overrides: { entries: [{ name: "DP-2" }] },
                expectedResolution: null
            }
        ];
    }

    function test_matchOverride(row) {
        const entry = Plan.matchOverride(row.monitor, row.overrides);
        if (row.expectedResolution === null) {
            verify(entry === null, "expected no match, got " + JSON.stringify(entry));
        } else {
            verify(entry !== null, "expected a match");
            compare(entry.resolution, row.expectedResolution);
        }
    }

    function test_applyOverrides_data() {
        return [
            {
                tag: "a partial override replaces only the fields it sets",
                monitors: [monitor60hz()],
                specs: [specFor("HDMI-A-1", "2560x1200@60", "1920x0", "1")],
                overrides: { entries: [{ name: "HDMI-A-1", resolution: "1920x1080@60" }] },
                expected: [{ resolution: "1920x1080@60", position: "1920x0", scale: "1" }]
            },
            {
                tag: "a full override replaces every field",
                monitors: [monitor240hz()],
                specs: [specFor("DP-1", "1920x1080@240", "0x0", "1")],
                overrides: {
                    entries: [{
                        name: "DP-1",
                        resolution: "2560x1440@120",
                        position: "0x0",
                        scale: 1.25,
                        transform: 2,
                        vrr: "left"
                    }]
                },
                expected: [{ resolution: "2560x1440@120", position: "0x0", scale: "1.25", transform: 2, vrr: "vrrleft" }]
            },
            {
                tag: "an overridden scale renders without a trailing zero",
                monitors: [monitor60hz()],
                specs: [specFor("HDMI-A-1", "2560x1200@60", "1920x0", "1")],
                overrides: { entries: [{ name: "HDMI-A-1", scale: 2.0 }] },
                expected: [{ scale: "2" }]
            }
        ];
    }

    function test_applyOverrides(row) {
        const out = Plan.applyOverrides(row.specs, row.monitors, row.overrides);
        for (let i = 0; i < row.expected.length; i++) {
            const want = row.expected[i];
            for (const key in want)
                compare(out[i][key], want[key]);
        }
    }
}
