// The idle-to-lock state machine.
//
// This is the security item of the Quickshell consolidation, and the thing
// it protects against is the machine quietly not locking. So the assertions
// below are about the two directions that can fail silently: a quiet session
// must reach LOCKED and emit `loginctl lock-session` exactly once, and a
// session someone came back to must reach ACTIVE having emitted no lock at
// all.
//
// Everything here runs with no compositor, no logind and no display, which
// is the whole reason idle.js exists as a separate file: IdleWatcher.qml
// binds Quickshell.Wayland's IdleMonitor and Quickshell.Io's Process, and
// qmltestrunner can instantiate neither (tests/README.md).
//
// The final section reads IdleWatcher.qml as text, tst_settings_wiring.qml's
// idiom, for the same reason: a green state machine wired to nothing would
// still be a machine that never locks.
import QtQuick
import QtTest
import "../../nix/home/desktop/quickshell/qml/idle/idle.js" as Idle
import "sourcescan.js" as Scan

TestCase {
    name: "Idle"

    // Feeds a run of events through the machine and collects both where it
    // ended up and every command it asked for along the way, so a test can
    // assert on the whole sequence rather than one edge at a time.
    function drive(events) {
        let phase = Idle.ACTIVE;
        const commands = [];

        for (const event of events) {
            const next = Idle.transition(phase, event);
            phase = next.phase;
            for (const command of next.commands)
                commands.push(command.join(" "));
        }

        return {
            phase: phase,
            commands: commands
        };
    }

    // ---- idle -> warn -> lock ----

    function test_a_quiet_session_blanks_then_locks() {
        const run = drive([Idle.BLANK, Idle.LOCK]);

        compare(run.phase, Idle.LOCKED);
        compare(run.commands, ["hyprctl dispatch dpms off", "loginctl lock-session"]);
    }

    function test_the_blank_threshold_alone_does_not_lock() {
        const run = drive([Idle.BLANK]);

        compare(run.phase, Idle.WARNED, "crossing the first threshold only warns");
        compare(run.commands, ["hyprctl dispatch dpms off"], "nothing may lock before the lock threshold");
    }

    // Both monitors keep reporting while the session stays quiet, so the same
    // event arrives more than once. A second dpms off is harmless; a second
    // lock-session would mean this file had lost track of what it had done.
    function test_repeated_thresholds_do_not_repeat_their_commands() {
        const run = drive([Idle.BLANK, Idle.BLANK, Idle.LOCK, Idle.LOCK, Idle.BLANK]);

        compare(run.phase, Idle.LOCKED);
        compare(run.commands, ["hyprctl dispatch dpms off", "loginctl lock-session"]);
    }

    // Equal timeouts, or a blank monitor held off by an inhibitor the lock
    // monitor outlasted. Either way a locked session must not be a lit one.
    function test_locking_without_a_prior_blank_blanks_first() {
        const run = drive([Idle.LOCK]);

        compare(run.phase, Idle.LOCKED);
        compare(run.commands, ["hyprctl dispatch dpms off", "loginctl lock-session"]);
    }

    // ---- activity cancels a pending lock ----

    function test_activity_while_warned_cancels_the_pending_lock() {
        const run = drive([Idle.BLANK, Idle.ACTIVITY, Idle.ACTIVITY]);

        compare(run.phase, Idle.ACTIVE);
        compare(run.commands, ["hyprctl dispatch dpms off", "hyprctl dispatch dpms on"]);
        verify(run.commands.indexOf("loginctl lock-session") === -1, "a cancelled lock must never have been issued");
    }

    // Coming back to a machine that did lock. The outputs are still asleep,
    // so without the dpms on there is nothing to type a password into.
    function test_activity_while_locked_lights_the_screen_back_up() {
        const run = drive([Idle.BLANK, Idle.LOCK, Idle.ACTIVITY]);

        compare(run.phase, Idle.ACTIVE);
        compare(run.commands[run.commands.length - 1], "hyprctl dispatch dpms on");
    }

    // Unlocking is not an event this watcher can see, so the way back to a
    // normal session is activity, and the thresholds have to arm again from
    // there or the machine locks exactly once per login.
    function test_the_cycle_arms_again_after_an_unlock() {
        const run = drive([Idle.BLANK, Idle.LOCK, Idle.ACTIVITY, Idle.BLANK, Idle.LOCK]);

        compare(run.phase, Idle.LOCKED);
        compare(run.commands.filter(c => c === "loginctl lock-session").length, 2, "the second quiet stretch must lock too");
    }

    function test_activity_on_an_already_active_session_does_nothing() {
        const run = drive([Idle.ACTIVITY]);

        compare(run.phase, Idle.ACTIVE);
        compare(run.commands, []);
    }

    // A state nobody wrote is read as ACTIVE rather than left alone: the
    // failure that matters here is a watcher stranded somewhere it can never
    // leave, which is a machine that has stopped locking.
    function test_an_unknown_state_still_locks() {
        const next = Idle.transition("nonsense", Idle.LOCK);

        compare(next.phase, Idle.LOCKED);
        compare(next.commands.map(c => c.join(" ")), ["hyprctl dispatch dpms off", "loginctl lock-session"]);
    }

    function test_an_unknown_event_changes_nothing() {
        const next = Idle.transition(Idle.WARNED, "sneeze");

        compare(next.phase, Idle.WARNED);
        compare(next.commands, []);
    }

    // ---- the failed-lock retry ----

    function test_a_failed_lock_falls_back_to_the_target_the_keybind_uses() {
        const retry = Idle.fallbackFor(Idle.lockCommand(), 1);

        compare(retry, ["systemctl", "--user", "start", "lock.target"]);
    }

    function test_nothing_is_retried_when_there_is_nothing_to_retry_data() {
        return [
            { tag: "lock succeeded", command: Idle.lockCommand(), exitCode: 0 },
            { tag: "dpms failed", command: Idle.dpmsCommand("off"), exitCode: 1 },
            { tag: "the fallback itself failed", command: Idle.lockFallbackCommand(), exitCode: 1 }
        ];
    }

    function test_nothing_is_retried_when_there_is_nothing_to_retry(row) {
        compare(Idle.fallbackFor(row.command, row.exitCode), null, row.tag);
    }

    // ---- timeouts ----

    function test_timeouts_pass_sane_values_through() {
        const t = Idle.timeouts(300, 600);

        compare(t.blank, 300);
        compare(t.lock, 600);
    }

    // IdleMonitor reads a zero timeout as "idle immediately", so a key the
    // JSON did not carry, read as 0, would lock the screen the moment the
    // shell started. Every unusable value lands on the defaults instead.
    function test_an_unusable_value_falls_back_to_the_default_data() {
        return [
            { tag: "missing", blank: 0, lock: 0 },
            { tag: "undefined", blank: undefined, lock: undefined },
            { tag: "null", blank: null, lock: null },
            { tag: "negative", blank: -1, lock: -1 },
            { tag: "not a number", blank: "soon", lock: "later" }
        ];
    }

    function test_an_unusable_value_falls_back_to_the_default(row) {
        const t = Idle.timeouts(row.blank, row.lock);

        compare(t.blank, Idle.DEFAULT_BLANK_SECONDS, row.tag);
        compare(t.lock, Idle.DEFAULT_LOCK_SECONDS, row.tag);
    }

    // A lock timeout shorter than the blank one pulls the blank in, never
    // the other way around: no arrangement of the two numbers may push the
    // lock later than what was asked for.
    function test_a_lock_shorter_than_the_blank_pulls_the_blank_in() {
        const t = Idle.timeouts(600, 120);

        compare(t.lock, 120);
        compare(t.blank, 120);
    }

    // Someone who typed 5 wants to lock sooner, not to be ignored back up to
    // ten minutes, so a positive value under the floor is clamped rather
    // than discarded.
    function test_a_value_under_the_floor_is_clamped_not_discarded() {
        const t = Idle.timeouts(1, 5);

        compare(t.blank, Idle.MINIMUM_SECONDS);
        compare(t.lock, Idle.MINIMUM_SECONDS);
    }

    // ---- wiring ----

    function watcherSource() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../nix/home/desktop/quickshell/qml/idle/IdleWatcher.qml"), false);
        xhr.send();
        compare(xhr.status, 200, "IdleWatcher.qml must be readable (needs QML_XHR_ALLOW_FILE_READ=1)");
        return Scan.stripComments(xhr.responseText);
    }

    function test_the_watcher_binds_both_thresholds_to_a_real_idle_monitor() {
        const src = watcherSource();

        compare(src.split("IdleMonitor {").length - 1, 2, "one IdleMonitor per threshold");
        verify(src.indexOf("timeout: root.timeouts.blank") !== -1, "the blank monitor must read the sanitised blank timeout");
        verify(src.indexOf("timeout: root.timeouts.lock") !== -1, "the lock monitor must read the sanitised lock timeout");
    }

    // The state machine is only worth testing if its output is what runs.
    function test_the_watcher_runs_what_the_state_machine_returned() {
        const handle = Scan.blockAfter(watcherSource(), "function handle(event: string): void {");

        verify(handle.indexOf("Idle.transition(root.phase, event)") !== -1, "the watcher must ask idle.js what to do");
        verify(handle.indexOf("root.run(command)") !== -1, "and must run every command it got back");
    }

    // Reusing the existing lock path is the constraint this whole item was
    // written under: no PAM, no second authenticator, nothing that unlocks.
    function test_the_watcher_reaches_the_lock_only_through_the_existing_path() {
        const src = watcherSource();

        verify(src.indexOf("Idle.lockCommand()") !== -1, "the lock must be the argv idle.js builds");
        verify(src.indexOf("pam") === -1 && src.indexOf("Pam") === -1, "this file must never touch an authenticator");
        verify(src.indexOf("hyprlock") === -1, "hyprlock is reached through lock.target, never run directly");
    }
}
