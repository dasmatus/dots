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
import "sourcescan.js" as SourceScan

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

    // attemptCommandsForState is the guard Watcher.qml's stdout handler
    // calls instead of commandsForState directly — see watch.js's own
    // header. Motivating bug: `hyprctl monitors -j` run before Hyprland's
    // IPC socket exists produces exactly this kind of output, and
    // Plan.parseMonitors's contract (proved by tst_monitors.qml's
    // test_parseMonitors_rejects_garbage, which this file deliberately does
    // NOT relax) is to throw on all four, not shrug them off — an uncaught
    // throw from inside a StdioCollector.onStreamFinished handler cannot be
    // caught by anything upstream in Watcher.qml, so it silently dropped
    // that apply and left nothing in the log beyond a one-line WARN.
    function test_attemptCommandsForState_handles_malformed_output_data() {
        return [
            { tag: "empty", json: "" },
            { tag: "whitespace", json: "   \n\t  " },
            { tag: "truncated", json: "[{\"name\":\"DP-1\",\"description\":\"Ancor Comm" },
            { tag: "valid JSON, not an array", json: "{\"monitors\": []}" }
        ];
    }

    function test_attemptCommandsForState_handles_malformed_output(row) {
        let threw = false;
        let result;
        try {
            result = Watch.attemptCommandsForState(row.json, rulesOne(), { entries: [] });
        } catch (e) {
            threw = true;
        }
        verify(!threw, row.tag + ": must not throw out of attemptCommandsForState");
        compare(result.ok, false, row.tag + ": unparseable input must report ok:false");
        compare(result.commands.length, 0, row.tag + ": unparseable input must not produce commands");
    }

    // The distinction the guard exists to preserve: valid JSON describing
    // zero monitors (a real, successful read) is `ok:true` with no commands,
    // never confused with `ok:false` (the read produced nothing usable and
    // Watcher.qml should retry). Collapsing these into the same "empty
    // commands list" shape is exactly the "guard alone" failure mode the
    // fix has to avoid — it would leave Watcher.qml with no way to tell a
    // legitimate empty answer from a read that never really happened.
    function test_attemptCommandsForState_distinguishes_no_match_from_no_read() {
        const noMatch = Watch.attemptCommandsForState(monitorsJsonOne(), { rules: [] }, { entries: [] });
        compare(noMatch.ok, true);
        compare(noMatch.commands.length, 0);

        // try/catch rather than a bare call: attemptCommandsForState's whole
        // job is to never let this throw, so a mutation that removes its
        // guard must fail this test as a normal `compare` mismatch — the
        // same "genuine assertion failure, not a crash" bar every other test
        // here is held to — rather than as an uncaught exception out of a
        // test function that never claimed to expect one.
        let threw = false;
        let noRead = { ok: true, commands: null };
        try {
            noRead = Watch.attemptCommandsForState("", rulesOne(), { entries: [] });
        } catch (e) {
            threw = true;
        }
        verify(!threw, "attemptCommandsForState must not throw on empty input");
        compare(noRead.ok, false);
        compare(noRead.commands.length, 0);
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

    // Everything below this point pins the retry Watcher.qml itself builds
    // around attemptCommandsForState. qmltestrunner cannot instantiate
    // Watcher.qml — it reaches Quickshell.Io's FileView/Process, same gap
    // the adapter tests above work around — so none of this drives a real
    // Process or Timer; it is source-text pinning only, proving the shape of
    // the fix is still there, not that a live retry loop behaves correctly.
    // The behavioural half (attemptCommandsForState itself never throwing,
    // and telling "no read" apart from "no match") is covered above with no
    // source-scanning involved.
    function readCode(relPath) {
        return SourceScan.stripComments(readSource(relPath));
    }

    // jsonAdapterBlocks above already depth-matches braces from a fixed
    // start; this is the same scan generalised to start at a caller-given
    // index, needed because "function apply(): void {" appears twice in
    // Watcher.qml — the IpcHandler's own forwarding method, and root's own —
    // and only the second is the one that resets the retry budget.
    function blockFrom(source, markerStart) {
        const open = source.indexOf("{", markerStart);
        let depth = 0;
        for (let i = open; i < source.length; i++) {
            if (source[i] === "{")
                depth++;
            else if (source[i] === "}") {
                depth--;
                if (depth === 0)
                    return source.slice(markerStart, i + 1);
            }
        }
        return "";
    }

    function nthIndexOf(source, marker, n) {
        let idx = -1;
        for (let i = 0; i < n; i++) {
            idx = source.indexOf(marker, idx + 1);
            if (idx === -1)
                return -1;
        }
        return idx;
    }

    // The exact call the original bug went through: `Watch.commandsForState`
    // called straight from onStreamFinished, with nothing between it and an
    // uncaught JSON.parse SyntaxError. If this ever comes back, it comes
    // back silently — qmllint has no opinion on which of watch.js's two
    // functions gets called — so it is pinned here instead.
    function test_watcher_stdout_handler_uses_the_guarded_reader() {
        const watcher = readCode("../../nix/home/quickshell/qml/monitors/Watcher.qml");
        verify(watcher.indexOf("Watch.attemptCommandsForState(") !== -1, "the stdout handler must call watch.js's guarded reader — calling the throwing commandsForState directly is the original bug, an uncaught SyntaxError from a `hyprctl monitors -j` read that raced Hyprland's socket coming up");
        verify(watcher.indexOf("Watch.commandsForState(this.text") === -1, "the stdout handler must not call the throwing commandsForState directly");
    }

    // A retry loop with no bound is its own bug against a compositor that
    // never comes up; a bound with no way to discover it happened is a
    // silent no-op wearing the shape of a fix. Both properties are pinned
    // together because neither alone is the thing this task asked for.
    function test_watcher_retry_budget_is_a_small_finite_number() {
        const watcher = readCode("../../nix/home/quickshell/qml/monitors/Watcher.qml");
        const match = watcher.match(/readonly property int maxRetries:\s*(\d+)/);
        verify(match !== null, "maxRetries must be a literal integer bound, not computed or absent");
        const bound = parseInt(match[1], 10);
        verify(bound > 0 && bound <= 20, "the retry bound must be small and finite, got " + bound);
    }

    function test_watcher_gives_up_with_a_log_line_once_the_budget_is_spent() {
        const watcher = readCode("../../nix/home/quickshell/qml/monitors/Watcher.qml");
        const body = SourceScan.blockAfter(watcher, "function handleRead(result): void {");
        verify(body !== "", "handleRead must exist and be brace-matched");
        verify(body.indexOf("retriesLeft <= 0") !== -1, "handleRead must check the retry budget before retrying again");
        verify(body.indexOf("console.warn(") !== -1, "giving up must log — a guard with no log turns a loud failure into a mute one");
        verify(body.indexOf("retriesLeft--") !== -1, "a retry must spend one attempt from the bounded budget");
        verify(body.indexOf("retryTimer.restart()") !== -1, "a retry must actually schedule another read, not just remember that one failed");
    }

    // The branch that does the work every retry above exists to reach, and
    // the one the checks above cannot see: they look for substrings anywhere
    // in handleRead's body, so gutting the successful-read branch (parse the
    // monitors, then apply nothing) and inverting its condition (apply on the
    // read that failed, retry the one that worked) both leave every one of
    // those substrings exactly where it was. Both mutations reproduce the
    // silent no-op this whole file exists to remove, and both were confirmed
    // to do so against a live quickshell driving the real Watcher.qml with a
    // stubbed hyprctl on PATH: reads succeeded and zero `hyprctl eval` calls
    // were issued, with the suite still fully green.
    function test_watcher_applies_the_layout_on_a_successful_read() {
        const watcher = readCode("../../nix/home/quickshell/qml/monitors/Watcher.qml");
        const body = SourceScan.blockAfter(watcher, "function handleRead(result): void {");
        verify(body !== "", "handleRead must exist and be brace-matched");

        const start = body.indexOf("if (result.ok) {");
        verify(start !== -1, "handleRead must branch on result.ok directly — inverted, it retries every read that worked and applies every one that did not");

        const success = blockFrom(body, start);
        verify(success.indexOf("root.runCommands(result.commands)") !== -1, "the successful-read branch must apply the commands it just parsed — without it the read and the retry both run to completion and change nothing");
    }

    // The read the retry schedules has to happen: pinned separately from the
    // budget-accounting checks above because a handleRead that decremented
    // the counter and logged correctly but forgot to restart the timer, or a
    // timer that logged instead of reading again, would pass every check
    // above and still never re-apply the layout.
    function test_watcher_retry_timer_restarts_the_read() {
        const watcher = readCode("../../nix/home/quickshell/qml/monitors/Watcher.qml");
        verify(watcher.indexOf("onTriggered: root.startRead()") !== -1, "retryTimer must call startRead() when it fires");
    }

    // apply() is every EXTERNAL trigger's entry point (startup, either
    // FileView's onLoaded, the debounced Hyprland event, the IPC handler).
    // If it did not reset retriesLeft, a session that spent its whole retry
    // budget once early on (e.g. a slow-starting Hyprland) would have every
    // later, unrelated trigger — a real monitoradded event, a deliberate
    // `qs ipc call monitors apply` — silently refuse to retry a read that
    // itself raced the same way, for the rest of the session.
    function test_watcher_apply_gives_every_external_trigger_a_fresh_retry_budget() {
        const watcher = readCode("../../nix/home/quickshell/qml/monitors/Watcher.qml");
        const marker = "function apply(): void {";
        const start = nthIndexOf(watcher, marker, 2);
        verify(start !== -1, "root's own apply() (distinct from the IpcHandler's forwarding method of the same name) must exist");
        const body = blockFrom(watcher, start);
        verify(body.indexOf("root.retriesLeft = root.maxRetries") !== -1, "apply() must reset the retry budget so a trigger unrelated to an earlier exhausted one is not starved by it");
        verify(body.indexOf("root.startRead()") !== -1, "apply() must still start a read after resetting the budget");
    }
}
