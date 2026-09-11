// Every decision the idle watcher makes, as pure functions over strings and
// numbers.
//
// Split out of IdleWatcher.qml for the reason tests/README.md gives: the
// component binds Quickshell.Wayland's IdleMonitor and Quickshell.Io's
// Process, and qmltestrunner can instantiate neither. A test that wanted to
// prove "a quiet screen blanks, a quieter one locks, and touching the
// keyboard cancels the pending lock" would otherwise need a compositor and a
// logind session before it could assert anything at all.
//
// Commands come back as argv arrays instead of being run, the same shape
// monitors/watch.js hands back its hyprctl lines in: the argv is the part
// that has to be exactly right, and a test can read it.
.pragma library

// The three states. WARNED is "screen off, lock pending": the blank is the
// warning, and it is the only warning worth giving, because the person this
// would warn has by definition walked away from the screen a countdown
// would be drawn on.
var ACTIVE = "active";
var WARNED = "warned";
var LOCKED = "locked";

// The three things that can happen. BLANK and LOCK are the two idle
// thresholds coming due; ACTIVITY is either of them being withdrawn, which
// ext-idle-notify-v1 reports the moment the user touches anything.
var BLANK = "blank";
var LOCK = "lock";
var ACTIVITY = "activity";

// Fallbacks for a timeouts file that is missing, truncated or hand-edited
// into nonsense. They match nix/system/defaults.nix, which is where the real
// values come from on an installed machine; these exist so that a shell
// which cannot read the file still locks rather than still not locking.
var DEFAULT_BLANK_SECONDS = 300;
var DEFAULT_LOCK_SECONDS = 600;

// Below this a threshold is not a policy, it is a machine that locks while
// you read. A positive value under the floor is clamped up to it rather than
// discarded, because someone who typed 5 wants to lock sooner, not later.
var MINIMUM_SECONDS = 10;

// `hyprctl dispatch dpms off|on`. Hyprland's own dispatcher rather than a
// DRM call, for the same reason monitors/watch.js shells out: the compositor
// owns the outputs and there is no Quickshell binding that does this.
function dpmsCommand(power) {
    return ["hyprctl", "dispatch", "dpms", power];
}

// Ask logind to lock, rather than starting lock.target or running hyprlock.
// All three end at the same unit, but only this one also tells logind the
// session is locked, so `loginctl show-session` reports LockedHint=yes and
// anything else watching for the D-Bus signal sees it too.
function lockCommand() {
    return ["loginctl", "lock-session"];
}

// What to try when the call above fails. The shell runs as a unit under the
// systemd user manager, not inside the login session's own scope, so
// resolving "my session" from the caller's PID is not guaranteed to work the
// way it does for a process the compositor spawned. Starting lock.target
// directly reaches the same hyprlock.service and is what the SUPER+ALT+L
// bind already does (nix/home/desktop/session/default.nix's commandDefaults),
// so the fallback is a path this machine has been using all along.
function lockFallbackCommand() {
    return ["systemctl", "--user", "start", "lock.target"];
}

// The state machine. Returns the state to move to and the commands that move
// belongs to, never mutating what it was handed.
//
// An unrecognised state is read as ACTIVE. This is a security path: the
// failure that matters is a machine that stops locking, and treating a
// state nobody wrote as "the user is here" keeps both thresholds live
// instead of stranding the watcher somewhere it can never leave.
function transition(phase, event) {
    var from = (phase === WARNED || phase === LOCKED) ? phase : ACTIVE;

    // Activity always returns to ACTIVE, and lights the screen back up if it
    // was off. The lock screen needs this as much as the desktop does: after
    // a lock the outputs are still asleep, and without the dpms on there is
    // nothing to type a password into.
    if (event === ACTIVITY)
        return { phase: ACTIVE, commands: from === ACTIVE ? [] : [dpmsCommand("on")] };

    if (event === BLANK) {
        if (from === ACTIVE)
            return { phase: WARNED, commands: [dpmsCommand("off")] };

        // Already blanked, or already locked and blanked with it. Both
        // monitors re-report on their own, so this arrives more than once.
        return { phase: from, commands: [] };
    }

    if (event === LOCK) {
        // Locking twice is not harmful — the target is already up and
        // systemd does nothing — but issuing it twice would mean this file
        // has lost track of what it did, so it is spelled out rather than
        // left to logind's tolerance.
        if (from === LOCKED)
            return { phase: LOCKED, commands: [] };

        // Reaching the lock threshold without having passed the blank one
        // means the two were configured equal, or the blank monitor was held
        // off by an inhibitor that the lock monitor outlasted. Blank first
        // either way, so a locked session is never a lit one.
        if (from === ACTIVE)
            return { phase: LOCKED, commands: [dpmsCommand("off"), lockCommand()] };

        return { phase: LOCKED, commands: [lockCommand()] };
    }

    return { phase: from, commands: [] };
}

// Which of the two things a command out of transition() is, so the caller
// can send it to the process that runs that kind of thing without matching
// on argv itself.
function isLockCommand(command) {
    return !!command && command.join(" ") === lockCommand().join(" ");
}

// null when there is nothing to retry: the command succeeded, or it was not
// the lock. Only the lock has a second route worth taking; a failed dpms
// call leaves a lit screen, which is visible and harmless, while a failed
// lock leaves an open session, which is neither.
function fallbackFor(command, exitCode) {
    if (exitCode === 0 || !isLockCommand(command))
        return null;

    return lockFallbackCommand();
}

// One threshold, sanitised. Anything that is not a positive number falls
// back to the default rather than to zero: IdleMonitor treats a zero timeout
// as "idle immediately", so a missing key read as 0 would lock the screen
// the instant the shell started.
function seconds(value, fallback) {
    var parsed = Number(value);

    if (!isFinite(parsed) || parsed <= 0)
        return fallback;

    return Math.max(MINIMUM_SECONDS, Math.round(parsed));
}

// Both thresholds, sanitised together. A lock timeout shorter than the blank
// one pulls the blank in to meet it, never the other way around: the point
// of the pair is when the session locks, and no arrangement of these two
// numbers may push that later than what was asked for.
function timeouts(blankSeconds, lockSeconds) {
    var lock = seconds(lockSeconds, DEFAULT_LOCK_SECONDS);
    var blank = seconds(blankSeconds, DEFAULT_BLANK_SECONDS);

    return { blank: Math.min(blank, lock), lock: lock };
}
