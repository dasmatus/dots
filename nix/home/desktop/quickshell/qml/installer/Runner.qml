// The install runner, install.rs::run()/exec_step(), ported. `run(actions)`
// walks the ordered list plan.js's planFor() (or, in a test, a harmless
// stand-in of the same shape) produces, one Process at a time: the next
// action starts only once the previous one has exited, and a non-zero exit
// raises `failed` immediately, so nothing after it ever runs. Event shape
// mirrors install.rs's `Event` one signal per variant: `stepStarted`, `log`,
// `recoveryKey`, `finished`, `failed`.
//
// A single Process/SplitParser pair is reused across every step rather than
// one instance per action. Providers.qml's debounced file search reuses its
// Process across searches the same way, and actions here never overlap.
//
// `WriteFile` has no filesystem-write primitive of its own in QML, so it
// runs as `install -D -m <mode> /dev/stdin <path>`: `install -D` creates
// missing parent directories the way install.rs's `create_dir_all` does,
// `-m` sets the mode at creation rather than chmod-ing afterwards, and the
// contents travel over stdin, never through argv, never through a shell
// string. `WriteSecrets` pipes the plaintext through
// `mkpasswd -m yescrypt --stdin`, exactly like install.rs's `hash_password`,
// then re-enters the same install-based write with the resulting hash; the
// plaintext password is never written to disk or handed to a shell.
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

QtObject {
    id: root

    signal stepStarted(int index, int total, string title)
    signal log(string line)
    signal recoveryKey(string key)
    signal finished()
    signal failed(string message)

    property var _actions: []
    property int _index: 0
    property string _lastLine: ""
    // "run" for every ordinary action; WriteSecrets is the one kind needing
    // a second process (hash, then write), tracked here so the shared
    // Process's stdout/exit handlers know which half they are looking at.
    property string _phase: "run"
    property string _secretPath: ""

    /// Start walking `actions` from the top. Re-entrant calls are not
    /// supported: one plan runs to `finished`/`failed` before another may
    /// start, matching install.rs's single worker thread.
    function run(actions) {
        root._actions = actions;
        root._index = 0;
        root._runStep();
    }

    /// The current `{title, action}` step, plan.js's shape.
    function _step() {
        return root._actions[root._index];
    }

    function _octal(mode) {
        return mode.toString(8);
    }

    function _runStep() {
        if (root._index >= root._actions.length) {
            root.finished();
            return;
        }
        const step = root._step();
        const action = step.action;
        root.stepStarted(root._index + 1, root._actions.length, step.title);
        root._lastLine = "";
        root._phase = "run";

        if (action.kind === "WriteFile") {
            root._writeFile(action.path, action.contents, action.mode);
        } else if (action.kind === "WriteSecrets") {
            root._phase = "hashSecret";
            root._secretPath = action.path;
            proc.command = ["mkpasswd", "-m", "yescrypt", "--stdin"];
            proc._pendingStdin = action.userPassword;
            proc.stdinEnabled = true;
            proc.running = true;
        } else {
            proc.command = [action.program].concat(action.args);
            proc._pendingStdin = action.stdin ?? null;
            proc.stdinEnabled = proc._pendingStdin !== null;
            proc.running = true;
        }
    }

    function _writeFile(path, contents, mode) {
        proc.command = ["install", "-D", "-m", root._octal(mode), "/dev/stdin", path];
        proc._pendingStdin = contents;
        proc.stdinEnabled = true;
        proc.running = true;
    }

    property Process _proc: Process {
        id: proc

        property var _pendingStdin: null

        onStarted: {
            if (proc._pendingStdin !== null) {
                proc.write(proc._pendingStdin);
                // Close the write side so the reader on the other end (cat,
                // install, mkpasswd) sees EOF instead of blocking forever.
                proc.stdinEnabled = false;
                proc._pendingStdin = null;
            }
        }

        stdout: SplitParser {
            onRead: data => {
                if (root._phase === "hashSecret") {
                    if (data.trim().length > 0)
                        root._lastLine = data.trim();
                    return;
                }
                const action = root._step().action;
                if (action.kind === "Command" && action.capture === "RecoveryKey") {
                    // Kept out of the scrolling log; shown separately once
                    // captured. install.rs does the same on its Done screen.
                    if (data.trim().length > 0)
                        root._lastLine = data.trim();
                } else {
                    root.log(data);
                }
            }
        }

        // qmllint disable signal-handler-parameters
        onExited: exitCode => {
            const step = root._step();
            const action = step.action;

            if (exitCode !== 0) {
                root.failed(`${step.title}: ${proc.command[0]} exited with code ${exitCode}`);
                return;
            }

            if (root._phase === "hashSecret") {
                const hash = root._lastLine;
                // yescrypt hashes start "$y$"; install.rs checks the same
                // thing before trusting mkpasswd's stdout as a real hash.
                if (!hash.startsWith("$y$")) {
                    root.failed(`${step.title}: mkpasswd did not produce a yescrypt hash`);
                    return;
                }
                root._phase = "writeSecret";
                root._writeFile(root._secretPath, `{\n  userHash = "${hash}";\n}\n`, 384 /* 0o600 */);
                return;
            }

            if (action.kind === "Command" && action.capture === "RecoveryKey") {
                if (root._lastLine.length === 0) {
                    root.failed(`${step.title}: no recovery key captured`);
                    return;
                }
                root.recoveryKey(root._lastLine);
            }

            root._index += 1;
            root._runStep();
        }
        // qmllint enable signal-handler-parameters
    }
}
