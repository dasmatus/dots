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
}
