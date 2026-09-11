// Blanks the screen after one quiet stretch and locks the session after a
// longer one.
//
// Nothing in this repo owned idle before this file: no hypridle, no
// swayidle, no logind IdleAction. nix/home/default.nix's claim that the X11
// stack "has been fully replaced" held for swaylock and redshift and never
// held for swayidle, so a session left alone stayed lit and unlocked until
// someone came back to it. On a laptop that gives away most of what the rest
// of the hardening pass buys.
//
// It adds no authenticator, and must not. hyprlock.service
// (nix/home/desktop/hyprland.nix) is already WantedBy=lock.target with
// OnSuccess=unlock.target, and services.systemd-lock-handler
// (nix/modules/system/core.nix) already turns logind's Lock signal into that
// target. The whole job here is to produce the signal — the same one
// SUPER+ALT+L and a closed lid already produce — at the end of a quiet
// stretch.
//
// Two IdleMonitors rather than one plus a Timer: ext-idle-notify-v1 is what
// knows when the user last touched anything, and a Timer armed off the first
// threshold would have to re-derive "still idle" from a signal the
// compositor is already sending, then get the cancellation right by hand.
// hypridle's own config has this shape, one listener per threshold.
//
// Both monitors respect idle inhibitors, which is a real limit and worth
// stating plainly: an application holding one — a full-screen video,
// typically — defers the lock for as long as it holds it. That is what GNOME
// and KDE do with the same protocol, and the alternative, locking over a
// film someone is watching, is how a lock timeout gets switched off
// altogether. SUPER+ALT+L and the lid switch are unaffected either way.
//
// The state machine and the argv it produces live in idle.js so
// tests/qml/tst_idle.qml can drive them with no compositor and no logind.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "idle.js" as Idle

Scope {
    id: root

    // $XDG_CONFIG_HOME with the spec's fallback, copied from
    // monitors/Watcher.qml, which found the hard way that reading ~/.config
    // directly ignores a customised XDG_CONFIG_HOME and then looks for a
    // home-manager-written file somewhere it was never written.
    readonly property string configHome: {
        const xdg = Quickshell.env("XDG_CONFIG_HOME");
        return xdg && xdg.length > 0 ? xdg : Quickshell.env("HOME") + "/.config";
    }

    // Written by nix/home/desktop/quickshell/default.nix from dots.idle.*,
    // and a sibling of quickshell/ rather than inside it for the reason
    // monitors.json is: $XDG_CONFIG_HOME/quickshell is a symlink into the
    // built store tree, so nothing can be dropped beside shell.qml at
    // runtime.
    readonly property string timeoutsPath: root.configHome + "/dots-shell/idle.json"

    // Quickshell's qmltypes gives FileView.adapter the type FileViewAdapter
    // without exporting it, so qmllint cannot resolve anything reached
    // through it; monitors/Watcher.qml and the generated Theme.qml suppress
    // the same category for the same reason. Only a property DECLARED on the
    // adapter is populated from the file, which is why both are spelled out
    // here rather than read off a `root` that does not exist.
    // qmllint disable unresolved-type
    FileView {
        id: timeoutsFile

        path: root.timeoutsPath
        watchChanges: true
        onFileChanged: reload()
        adapter: JsonAdapter {
            property int blankSeconds: 0
            property int lockSeconds: 0
        }
    }

    // Zero above and zero here both mean "the file said nothing", which
    // idle.js turns into its own defaults rather than into a screen that
    // locks the instant the shell starts. A `home-manager switch` rewrites
    // the file and watchChanges picks the new values up with no restart.
    readonly property var timeouts: Idle.timeouts(timeoutsFile.adapter.blankSeconds, timeoutsFile.adapter.lockSeconds)
    // qmllint enable unresolved-type

    // Named phase rather than state: `state` is QtQuick's own property name
    // on anything derived from Item, and a state machine sharing a name with
    // the framework's is one refactor away from being driven by something
    // else.
    property string phase: Idle.ACTIVE

    IdleMonitor {
        id: blankMonitor

        timeout: root.timeouts.blank
        respectInhibitors: true
        onIsIdleChanged: root.handle(blankMonitor.isIdle ? Idle.BLANK : Idle.ACTIVITY)
    }

    IdleMonitor {
        id: lockMonitor

        timeout: root.timeouts.lock
        respectInhibitors: true
        onIsIdleChanged: root.handle(lockMonitor.isIdle ? Idle.LOCK : Idle.ACTIVITY)
    }

    function handle(event: string): void {
        const next = Idle.transition(root.phase, event);
        root.phase = next.phase;

        for (const command of next.commands)
            root.run(command);
    }

    // One Process per kind of command rather than one shared Process fed a
    // queue. The lock threshold can be crossed without the blank one having
    // been (idle.js's ACTIVE -> LOCKED edge), which emits two commands at
    // once, and a shared Process would have to sequence them on `exited` —
    // by which point its own `command` may already have been reassigned for
    // the next one, so the failed-lock retry below would be reading the
    // wrong argv. Separate processes have nothing to sequence.
    function run(command: var): void {
        if (Idle.isLockCommand(command)) {
            locker.running = false;
            locker.running = true;
            return;
        }

        dpms.command = command;
        dpms.running = false;
        dpms.running = true;
    }

    // `hyprctl dispatch dpms off|on`, the only command this file builds at
    // call time. Restarted the way monitors/Watcher.qml restarts its own
    // hyprctl read: a Process ignores a command reassigned under it, so the
    // false/true pair is what actually re-runs it.
    Process {
        id: dpms
    }

    Process {
        id: locker

        command: Idle.lockCommand()

        // qmllint disable signal-handler-parameters
        onExited: (exitCode, exitStatus) => {
            if (Idle.fallbackFor(locker.command, exitCode) === null)
                return;

            lockFallback.running = false;
            lockFallback.running = true;
        }
        // qmllint enable signal-handler-parameters
    }

    // Only reached when the call above fails. See idle.js's
    // lockFallbackCommand for why a second route exists at all: this shell
    // runs under the systemd user manager rather than inside the login
    // session's own scope, so logind resolving "my session" from the
    // caller is not something this file can assume.
    Process {
        id: lockFallback

        command: Idle.lockFallbackCommand()
    }
}
