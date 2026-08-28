// Pins plan.js against a real machine, so 2b can delete rust/hyprmon without
// the parity evidence going with it.
//
// fixtures/hyprctl-monitors.json is `hyprctl monitors -j` on the machine
// this was written on (read-only); fixtures/hyprmon-rules.json is that same
// machine's real ~/.config/hyprmon/rules.json; fixtures/hyprmon-overrides.json
// stands in for its absent overrides.json (Overrides::load() defaults to
// empty entries when the file is missing, so an empty entries array is the
// faithful fixture, not an arbitrary placeholder).
//
// fixtures/monitor-plan.dump is rust/hyprmon's OWN output for that exact
// input: a temporary `dump-plan` subcommand (match -> plan -> overrides ->
// render_lua(), no `apply`, no hyprctl eval) was added to
// rust/hyprmon/src/main.rs, run once against the saved JSON above, its
// stdout captured here, and the subcommand reverted immediately after — the
// plan doc's DO NOT MUTATE THE LIVE DESKTOP section is why this couldn't be
// `hyprmon apply` instead. `git diff` over rust/ carries no trace of it.
//
// Reading the fixtures needs QML_XHR_ALLOW_FILE_READ=1 (flake/apps.nix sets
// it on the qmltestrunner invocation); without it every readFixture call
// below throws "Invalid state" instead of returning file contents.
import QtQuick
import QtTest
import "../../nix/home/quickshell/qml/monitors/plan.js" as Plan

TestCase {
    name: "MonitorParity"

    function readFixture(name) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("fixtures/" + name), false);
        xhr.send();
        compare(xhr.status, 200, "fixture " + name + " must be readable (needs QML_XHR_ALLOW_FILE_READ=1)");
        return xhr.responseText;
    }

    // rust/hyprmon's Rule struct never renames match_name/match_description
    // to camelCase the way Monitor renames refreshRate etc — Rule's fields
    // aren't mirroring an external wire format, so serde just uses the Rust
    // names verbatim, and rules.json spells them with underscores on disk.
    // plan.js's matchRule/planFor take camelCase Rule objects (this port's
    // own in-memory convention); this adapts the one real config file this
    // test reads, standing in for whatever rules.json loader 2b ends up
    // owning.
    function adaptRule(r) {
        return {
            name: r.name,
            matchName: r.match_name,
            matchDescription: r.match_description,
            resolution: r.resolution,
            scale: r.scale,
            position: r.position,
            transform: r.transform,
            vrr: r.vrr
        };
    }

    function adaptRules(raw) {
        return { rules: (raw.rules || []).map(adaptRule) };
    }

    function test_matches_the_crates_real_dump() {
        const monitors = Plan.parseMonitors(readFixture("hyprctl-monitors.json"));
        const rules = adaptRules(JSON.parse(readFixture("hyprmon-rules.json")));
        const overrides = JSON.parse(readFixture("hyprmon-overrides.json"));

        const specs = Plan.planFor(monitors, rules, overrides);
        const rendered = specs.map(spec => Plan.render(spec));

        const expected = readFixture("monitor-plan.dump")
            .split("\n")
            .filter(line => line.length > 0);

        compare(rendered.length, expected.length);
        for (let i = 0; i < expected.length; i++)
            compare(rendered[i], expected[i]);
    }
}
