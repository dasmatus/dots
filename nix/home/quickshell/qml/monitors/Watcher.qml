// The monitor hotplug watcher — hyprmon.service's replacement, now living
// inside the shell process instead of its own systemd unit. That is a
// deliberate narrowing (see the 2b plan's Global Constraints): it starts
// slightly later, with `qs` rather than at login, and it exists only for the
// life of a graphical session. It also means the exec-once `hyprmon apply`
// line hyprland.nix used to run is gone — this watcher's own
// Component.onCompleted below is what applies the layout on shell startup
// now.
//
// ~/.config/dots-shell/monitors.json is the Nix-managed ruleset (written by
// nix/home/quickshell/default.nix — the rename off ~/.config/hyprmon/
// happened the same commit the crate did, since nothing else was left to own
// that path). ~/.config/dots-shell/overrides.json is Arrange.qml's output,
// which home-manager never touches, and which is absent until the drag
// surface is used once — a missing file lands both FileViews on the same
// empty-collection fallback matchRule/matchOverride already treat as "no
// constraint", so a fresh install with no overrides plans exactly as if the
// file did not exist, which it doesn't.
//
// planFor/render come from plan.js (2a); watch.js's commandsForState is this
// file's own contribution — the parse -> plan -> render -> argv chain, kept
// in a plain .pragma library, separate from apply()'s hyprctl process, so
// tests/qml/tst_watcher.qml can drive it with fixture JSON and assert on
// the exact argv it would run, with no live compositor anywhere near the
// test. watch.js's attemptCommandsForState wraps that chain for exactly the
// input a live `hyprctl monitors -j` can produce that no fixture-driven
// commandsForState() call ever needs to: nothing, because the socket was not
// up yet. See handleRead()/retryTimer below for what this file does with
// that "nothing" instead of letting it propagate as an uncaught exception.
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "watch.js" as Watch

Scope {
    id: root

    // $XDG_CONFIG_HOME, falling back to ~/.config the way the XDG base
    // directory spec requires — found by a headless test sandbox that set
    // XDG_CONFIG_HOME to an isolated tmpdir and had this file ignore it,
    // reading the real ~/.config instead (harmlessly, since nothing was
    // there yet, but a home-manager rebuild under a customised
    // XDG_CONFIG_HOME would have written the rules file somewhere this
    // watcher would never look).
    readonly property string configHome: {
        const xdg = Quickshell.env("XDG_CONFIG_HOME");
        return xdg && xdg.length > 0 ? xdg : Quickshell.env("HOME") + "/.config";
    }

    readonly property string rulesPath: root.configHome + "/dots-shell/monitors.json"
    readonly property string overridesPath: root.configHome + "/dots-shell/overrides.json"

    // Quickshell's qmltypes gives FileView.adapter the type FileViewAdapter
    // without exporting it, the same gap Theme.qml's own tintState works
    // around — see that file's header.
    //
    // JsonAdapter has no `root`: quickshell-io.qmltypes declares it (and its
    // FileViewAdapter prototype) with not one property, so reading a bare
    // `root` off it was silently undefined forever — matchRule/matchOverride
    // never saw a real rule and every hyprctl call this file exists to make
    // was skipped. Only a property DECLARED on the adapter instance below
    // gets populated from the file; `rules` and `overrides` are those two
    // properties, rewrapped into the { rules }/{ entries } shape
    // planFor()/applyOverrides() already take so neither function had to
    // change.
    // qmllint disable unresolved-type
    readonly property var rules: ({ rules: rulesFile.adapter.rules })
    readonly property var overrides: ({ entries: overridesFile.adapter.entries })

    FileView {
        id: rulesFile

        path: root.rulesPath
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.apply()
        adapter: JsonAdapter {
            property var rules: []
        }
    }

    FileView {
        id: overridesFile

        path: root.overridesPath
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.apply()
        adapter: JsonAdapter {
            property var entries: []
        }
    }
    // qmllint enable unresolved-type

    // rust/hyprmon's watch.rs TRIGGER_EVENTS: the only socket2 lines that
    // mean the monitor topology might have changed. configreloaded is kept
    // even though this watcher has no config file of its own to reload —
    // hyprland.lua itself can change which outputs a rule ends up seeing
    // (a transform or a disabled output added by hand), and that event is
    // the only signal the shell gets for it.
    readonly property var triggerEvents: ["monitoradded", "monitorremoved", "configreloaded"]

    Connections {
        target: Hyprland

        function onRawEvent(event) {
            if (root.triggerEvents.includes(event.name))
                debounce.restart();
        }
    }

    // Collapses a burst of events (unplugging a dock fires monitorremoved
    // once per output) into one apply — the same 300ms window watch.rs's own
    // DEBOUNCE used, so a dock unplug still settles into a single re-plan
    // rather than one per output coming loose.
    Timer {
        id: debounce

        interval: 300
        onTriggered: root.apply()
    }

    // The daemon's own "apply once on startup, don't wait for an event"
    // behaviour (watch.rs), now standing in for hyprland.nix's deleted
    // exec-once line. This is also the call most likely to race Hyprland's
    // own IPC socket coming up — see retriesLeft/retryTimer below for what
    // happens when it does.
    Component.onCompleted: root.apply()

    IpcHandler {
        target: "monitors"

        function apply(): void {
            root.apply();
        }
    }

    // Every external trigger — startup, a FileView reload, a debounced
    // Hyprland event, or this IPC handler — is "the world may have changed,
    // read again", and gets its own fresh retry budget: a read that is
    // still retrying from an earlier, unrelated trigger must not make a new,
    // independent trigger give up early. Only retriesLeft's own retryTimer
    // calls startRead() directly, skipping this reset, which is what keeps
    // the budget bounded instead of being refilled by its own retries.
    function apply(): void {
        root.retriesLeft = root.maxRetries;
        root.startRead();
    }

    function startRead(): void {
        monitorsProc.running = false;
        monitorsProc.running = true;
    }

    // Bounded retry for the startup race Component.onCompleted's apply() can
    // lose against Hyprland: `hyprctl monitors -j` run before the IPC socket
    // exists prints nothing and JSON.parse throws (the original bug — an
    // uncaught SyntaxError inside onStreamFinished, silently dropping the
    // apply with only a one-line WARN and no retry). Nothing else guarantees
    // a later apply() ever comes: the two FileViews' onLoaded already won
    // the race on the machine that surfaced this, and a laptop with no dock
    // fires no monitoradded/monitorremoved/configreloaded event for the rest
    // of the session either. 5 retries at 300ms apiece (the same interval
    // `debounce` above uses) is a 1.5s budget — generous for a compositor
    // socket to appear, but bounded, because a compositor that is genuinely
    // absent must not spin this forever.
    property int retriesLeft: 0
    readonly property int maxRetries: 5
    readonly property int retryIntervalMs: 300

    // Best-effort diagnostic only, never a retry input: `hyprctl`'s own exit
    // code is more truthful than guessing from stdout text alone (a
    // nonzero-exit run and a zero-exit run can both produce empty stdout,
    // but only one of them is hyprctl actually saying it failed), yet
    // Quickshell's docs give no ordering guarantee between Process.exited
    // and StdioCollector.streamFinished. Reading it only for the give-up log
    // — after every retry, never inside the same tick as the read it
    // describes — sidesteps that: hyprctl exits almost instantly, so by the
    // time a later attempt's give-up fires, this has long since settled.
    property int lastExitCode: 0

    // `hyprctl monitors -j`, the one live read this watcher does — never
    // Quickshell.Hyprland's own typed monitor list, which has no
    // availableModes/refreshRate/description-independent fields for
    // parseMonitors to read; see plan.js's own header for why those matter.
    Process {
        id: monitorsProc

        command: ["hyprctl", "monitors", "-j"]

        // qmllint disable signal-handler-parameters
        onExited: (exitCode, exitStatus) => root.lastExitCode = exitCode
        // qmllint enable signal-handler-parameters

        stdout: StdioCollector {
            onStreamFinished: root.handleRead(Watch.attemptCommandsForState(this.text, root.rules, root.overrides))
        }
    }

    // The result of one read: `ok` tells a read that produced nothing
    // usable (watch.js's attemptCommandsForState — see its own header) apart
    // from a read that legitimately matched no rules, which is not an error
    // and must not retry. Only the former spends the retry budget.
    function handleRead(result): void {
        if (result.ok) {
            root.retriesLeft = root.maxRetries;
            root.runCommands(result.commands);
            return;
        }

        if (root.retriesLeft <= 0) {
            console.warn("monitors: giving up after " + root.maxRetries + " failed `hyprctl monitors -j` reads (last exit code " + root.lastExitCode + "); monitor layout was not applied this session until the next monitoradded/monitorremoved/configreloaded event or `qs ipc call monitors apply`");
            return;
        }

        root.retriesLeft--;
        retryTimer.restart();
    }

    Timer {
        id: retryTimer

        interval: root.retryIntervalMs
        onTriggered: root.startRead()
    }

    function runCommands(commands) {
        for (const cmd of commands)
            root.runOne(cmd);
    }

    // Each spec gets its own Process instance, started independently of the
    // others: a bad mode or a monitor that vanished between the -j read and
    // this write fails that one `hyprctl eval` alone (its own stderr, sent to
    // journalctl the way Settings.qml's writer already is) rather than
    // taking every other output down with it.
    function runOne(cmd) {
        const runner = applyRunner.createObject(root, {
            command: cmd.argv
        });
        runner.running = true;
    }

    Component {
        id: applyRunner

        Process {
            // qmllint disable signal-handler-parameters
            onExited: (exitCode, exitStatus) => destroy()
            // qmllint enable signal-handler-parameters
        }
    }
}
