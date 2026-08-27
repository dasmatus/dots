# Devices & Files 2: Panes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use
> superpowers:subagent-driven-development or superpowers:executing-plans.

**Goal:** The second pane, and the write operations a dual-pane file
manager exists for: rename, mkdir, trash, copy, move.
**Architecture:** `Files.qml` grows `leftPath`/`rightPath`/`activeSide`;
`Pane.qml` grows `active` (owned by the parent, not itself) and a real
`selected` entry, because every operation below needs an operand that
survives past the click that made it. `operations.js` is five pure argv
builders, each ending in `--` before the path, extending the discipline
`preview.js`'s `previewCommand()` and `tests/qml/tst_preview.qml` already
established for this tree.
**Tech Stack:** Quickshell 0.3, Qt 6.11, coreutils `cp`/`mv`/`mkdir`,
`pkgs.glib`'s `gio trash`, QtTest.
**Spec:** `docs/superpowers/specs/2026-08-27-devices-files-design.md`

## Global Constraints
- Every `operations.js` builder returns an argv array with `--` before the
  path and the path as its own element — never a shell string, and never a
  bare path a leading `-` could turn into a flag.
- `active` lives on `Files.qml`, not on `Pane.qml` itself: only one side
  may be active, and a property a `Pane` set on itself could not enforce
  that across its sibling. A `Pane` asks for focus via `focusRequested()`
  instead of claiming it.
- No conflict resolution for copy/move onto an existing name — `cp`/`mv`'s
  own default behaviour is accepted as-is (see the spec's Open risks).
- `qmllint --max-warnings 0` (`nix run .#nix-lint`), unchanged gate.

---

### Task 1: The second pane

**Files:**
- Modify: `nix/home/quickshell/qml/files/Pane.qml`
- Modify: `nix/home/quickshell/qml/files/Files.qml`

**Produces:** `Pane.active` (required, parent-owned), `Pane.selected`,
`signal focusRequested()`. `Files.leftPath`/`rightPath`/`activeSide` and
`setActivePath(path)`, which `Devices.requestOpen` and `openPath` now both
call instead of writing a single `path`.

- [ ] **1** Replace `nix/home/quickshell/qml/files/Pane.qml` in full:

```qml
// One directory's listing. `ls -1Ap --group-directories-first` runs as
// direct argv with no shell — nothing on this path interpolates a path
// into a command string, so there is nothing here for a shell to need.
//
// `active` is owned by Files.qml, not by this file: only one side may be
// active at a time, and a property this file set on itself could not
// enforce that. A click anywhere in the pane asks the parent for focus via
// focusRequested() instead of claiming it directly.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "files.js" as FilesMath
import ".."

Rectangle {
    id: root

    required property string path
    required property bool active

    signal navigate(string path)
    signal focusRequested()

    property var entries: []
    property var selected: null

    color: Theme.bg
    border.width: root.active ? 2 : 0
    border.color: Theme.accent

    onPathChanged: root.list()
    Component.onCompleted: root.list()

    function list(): void {
        lsProc.command = ["ls", "-1Ap", "--group-directories-first", root.path];
        lsProc.running = true;
    }

    function activate(entry: var): void {
        const child = FilesMath.join(root.path, entry.name);

        if (entry.isDir) {
            root.navigate(child);
        } else {
            Quickshell.execDetached(["xdg-open", child]);
        }
    }

    Process {
        id: lsProc

        stdout: StdioCollector {
            onStreamFinished: root.entries = FilesMath.parseListing(this.text)
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: root.active ? 2 : 0
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Layout.margins: 8

            Text {
                text: "↑"
                color: Theme.fg
                font.family: Theme.fontUi

                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        root.focusRequested();
                        root.navigate(FilesMath.parentOf(root.path));
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                text: root.path
                color: Theme.muted
                font.family: Theme.fontMono
                elide: Text.ElideMiddle
            }
        }

        ListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true

            model: root.entries

            delegate: Rectangle {
                id: row

                required property var modelData

                width: ListView.view.width
                height: 28
                color: root.selected === row.modelData ? Theme.bgDark : "transparent"

                Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 12

                    text: (row.modelData.isDir ? "▸ " : "") + row.modelData.name
                    color: Theme.fg
                    font.family: Theme.fontUi
                }

                MouseArea {
                    anchors.fill: parent

                    onClicked: {
                        root.focusRequested();
                        root.selected = row.modelData;
                    }
                    onDoubleClicked: root.activate(row.modelData)
                }
            }
        }
    }
}
```

- [ ] **2** Replace `nix/home/quickshell/qml/files/Files.qml` in full:

```qml
// The file manager's outer shell, now two Panes: leftPath/rightPath persist
// independently, and activeSide says which one write operations (added
// later in this plan) act on. Devices.requestOpen and openPath both target
// whichever side is active, through setActivePath — the same single
// entrypoint Plan 1 established, extended rather than replaced.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../services"

Scope {
    id: root

    property string leftPath: Quickshell.env("HOME")
    property string rightPath: Quickshell.env("HOME")
    property string activeSide: "left"

    readonly property var activePane: root.activeSide === "left" ? leftPane : rightPane
    readonly property var otherPane: root.activeSide === "left" ? rightPane : leftPane

    function open(): void {
        window.visible = true;
    }

    function close(): void {
        window.visible = false;
    }

    function toggle(): void {
        window.visible = !window.visible;
    }

    function setActivePath(path: string): void {
        if (root.activeSide === "left")
            root.leftPath = path;
        else
            root.rightPath = path;
    }

    Connections {
        target: Devices

        function onRequestOpen(path) {
            root.setActivePath(path);
            root.open();
        }
    }

    IpcHandler {
        target: "files"

        function open(): void {
            root.open();
        }

        function close(): void {
            root.close();
        }

        function toggle(): void {
            root.toggle();
        }

        function openPath(path: string): void {
            root.setActivePath(path);
            root.open();
        }
    }

    FloatingWindow {
        id: window

        visible: false
        implicitWidth: 1200
        implicitHeight: 600

        ColumnLayout {
            anchors.fill: parent
            spacing: 0

            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                Sidebar {
                    Layout.fillHeight: true
                    Layout.preferredWidth: 200
                }

                Pane {
                    id: leftPane

                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    path: root.leftPath
                    active: root.activeSide === "left"
                    onNavigate: (path) => root.leftPath = path
                    onFocusRequested: root.activeSide = "left"
                }

                Pane {
                    id: rightPane

                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    path: root.rightPath
                    active: root.activeSide === "right"
                    onNavigate: (path) => root.rightPath = path
                    onFocusRequested: root.activeSide = "right"
                }
            }
        }
    }
}
```

- [ ] **3** `nix run .#nix-lint`
      Expected: green

- [ ] **4** `qs ipc call files toggle`
      Expected: two panes, both starting at `$HOME`; clicking a row in the
      left pane draws a 2px accent border around it and none around the
      right; clicking the right pane moves the border there; navigating one
      side leaves the other's path unchanged

- [ ] **5** `git add nix/home/quickshell/qml/files/Pane.qml nix/home/quickshell/qml/files/Files.qml`
      `git commit -m "feat: add a second pane to the file manager"`

---

### Task 2: Copy and move between panes

**Files:**
- Create: `nix/home/quickshell/qml/files/operations.js`
- Create: `tests/qml/tst_files_operations.qml`
- Modify: `nix/home/quickshell/qml/files/Files.qml`

**Produces:** `operations.js` exporting `copyArgv`, `moveArgv`,
`renameArgv`, `mkdirArgv`, `trashArgv`. A toolbar with "Copy →" and
"Move →" acting on the active pane's `selected` entry, into the other
pane's current directory.

- [ ] **1** Write `tests/qml/tst_files_operations.qml`:

```qml
// Every builder returns an array with the path as its own element and
// "--" ahead of it — the same argv-not-a-shell-string discipline
// tst_preview.qml already proves for previewCommand, extended to a name
// that could otherwise be parsed as a flag.
import QtQuick
import QtTest
import "../../nix/home/quickshell/qml/files/operations.js" as Operations

TestCase {
    name: "FilesOperations"

    property string nasty: "; rm -rf ~"

    function test_copyargv_keeps_each_path_as_its_own_argv_element() {
        compare(Operations.copyArgv(nasty, "/home/matus/dst"), ["cp", "-r", "--", nasty, "/home/matus/dst"]);
    }

    function test_moveargv_keeps_each_path_as_its_own_argv_element() {
        compare(Operations.moveArgv(nasty, "/home/matus/dst"), ["mv", "--", nasty, "/home/matus/dst"]);
    }

    function test_renameargv_keeps_each_path_as_its_own_argv_element() {
        compare(Operations.renameArgv("/home/matus/old", nasty), ["mv", "--", "/home/matus/old", nasty]);
    }

    function test_mkdirargv_keeps_the_path_as_its_own_argv_element() {
        compare(Operations.mkdirArgv(nasty), ["mkdir", "--", nasty]);
    }

    function test_trashargv_keeps_the_path_as_its_own_argv_element() {
        compare(Operations.trashArgv(nasty), ["gio", "trash", "--", nasty]);
    }

    function test_every_builder_uses_the_end_of_options_marker() {
        verify(Operations.copyArgv("-rf", "dst").includes("--"));
        verify(Operations.moveArgv("-rf", "dst").includes("--"));
        verify(Operations.renameArgv("-rf", "dst").includes("--"));
        verify(Operations.mkdirArgv("-rf").includes("--"));
        verify(Operations.trashArgv("-rf").includes("--"));
    }
}
```

- [ ] **2** Run QtTest
      Expected: FAIL, "files/operations.js: no such file"

- [ ] **3** Write `nix/home/quickshell/qml/files/operations.js`:

```js
// Argv builders for the write operations Files.qml's toolbar drives. Every
// one ends "--" before the path — the coreutils/gio convention that stops
// a name starting with "-" being parsed as a flag — and every path is its
// own array element, never concatenated into a shell string, because
// nothing on this path ever runs through sh -c.
.pragma library

function copyArgv(src, dst) {
    return ["cp", "-r", "--", src, dst];
}

function moveArgv(src, dst) {
    return ["mv", "--", src, dst];
}

function renameArgv(oldPath, newPath) {
    return ["mv", "--", oldPath, newPath];
}

function mkdirArgv(path) {
    return ["mkdir", "--", path];
}

function trashArgv(path) {
    return ["gio", "trash", "--", path];
}
```

- [ ] **4** Run QtTest again
      Expected: PASS, 6/6

- [ ] **5** In `Files.qml`, add imports and functions:

```qml
import "files.js" as FilesMath
import "operations.js" as Operations
```

```qml
    function copySelected(): void {
        const pane = root.activePane;
        if (!pane.selected)
            return;

        root.runOperation(Operations.copyArgv(FilesMath.join(pane.path, pane.selected.name), root.otherPane.path));
    }

    function moveSelected(): void {
        const pane = root.activePane;
        if (!pane.selected)
            return;

        root.runOperation(Operations.moveArgv(FilesMath.join(pane.path, pane.selected.name), root.otherPane.path));
    }

    function runOperation(argv: var): void {
        const runner = opRunner.createObject(root, { command: argv });
        runner.running = true;
    }

    Component {
        id: opRunner

        Process {
            // qmllint disable signal-handler-parameters
            onExited: (exitCode, exitStatus) => {
                leftPane.list();
                rightPane.list();
                destroy();
            }
            // qmllint enable signal-handler-parameters
        }
    }
```

- [ ] **6** In `Files.qml`, add a toolbar `RowLayout` above the panes'
      `RowLayout`, inside the `ColumnLayout`:

```qml
            RowLayout {
                Layout.fillWidth: true
                Layout.margins: 4
                spacing: 12

                Text {
                    text: "Copy →"
                    color: Theme.fg
                    font.family: Theme.fontUi

                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.copySelected()
                    }
                }

                Text {
                    text: "Move →"
                    color: Theme.fg
                    font.family: Theme.fontUi

                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.moveSelected()
                    }
                }
            }
```

  (this references `Theme`; add `import ".."` to `Files.qml` alongside its
  other imports)

- [ ] **7** `nix run .#nix-lint`
      Expected: green

- [ ] **8** `mkdir -p /tmp/probe-copy && echo hi > /tmp/probe-copy/a.txt`.
      `qs ipc call files toggle`, navigate the left pane to
      `/tmp/probe-copy`, click `a.txt` to select it, navigate the right
      pane anywhere else, click "Copy →"
      Expected: `a.txt` appears in the right pane's listing within a
      second, and `/tmp/probe-copy/a.txt` still exists (copy, not move)

- [ ] **9** Repeat with "Move →" instead
      Expected: `a.txt` appears in the right pane and disappears from
      `/tmp/probe-copy` in the left one

- [ ] **10** `rm -rf /tmp/probe-copy`

- [ ] **11** `git add nix/home/quickshell/qml/files/operations.js nix/home/quickshell/qml/files/Files.qml tests/qml/tst_files_operations.qml`
      `git commit -m "feat: copy and move between panes"`

---

### Task 3: Rename

**Files:** Modify `nix/home/quickshell/qml/files/Files.qml`.
**Produces:** an inline rename prompt, reused by Task 4's mkdir prompt.

- [ ] **1** Add properties and functions:

```qml
    property string promptMode: ""
    property string promptText: ""

    function beginRename(): void {
        if (!root.activePane.selected)
            return;

        root.promptMode = "rename";
        root.promptText = root.activePane.selected.name;
    }

    function confirmPrompt(): void {
        if (root.promptMode === "rename") {
            const oldPath = FilesMath.join(root.activePane.path, root.activePane.selected.name);
            const newPath = FilesMath.join(root.activePane.path, root.promptText);
            root.runOperation(Operations.renameArgv(oldPath, newPath));
        }

        root.promptMode = "";
    }

    function cancelPrompt(): void {
        root.promptMode = "";
    }
```

- [ ] **2** Add to the toolbar `RowLayout`:

```qml
                Text {
                    text: "Rename"
                    color: Theme.fg
                    font.family: Theme.fontUi

                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.beginRename()
                    }
                }

                TextInput {
                    Layout.preferredWidth: 200
                    visible: root.promptMode !== ""
                    text: root.promptText
                    color: Theme.fg
                    font.family: Theme.fontUi

                    onTextChanged: root.promptText = text
                    onVisibleChanged: if (visible) forceActiveFocus()

                    Keys.onReturnPressed: root.confirmPrompt()
                    Keys.onEscapePressed: root.cancelPrompt()
                }
```

- [ ] **3** `nix run .#nix-lint`
      Expected: green

- [ ] **4** `touch /tmp/probe-rename.txt`.
      `qs ipc call files openPath /tmp`, click `probe-rename.txt` to
      select it, click "Rename", clear the field and type
      `probe-renamed.txt`, press Enter
      Expected: `/tmp/probe-rename.txt` is gone, `/tmp/probe-renamed.txt`
      exists, and the pane's listing reflects it immediately (no manual
      refresh needed)

- [ ] **5** `rm -f /tmp/probe-renamed.txt`

- [ ] **6** `git add nix/home/quickshell/qml/files/Files.qml`
      `git commit -m "feat: rename entries in place"`

---

### Task 4: New folder

**Files:** Modify `nix/home/quickshell/qml/files/Files.qml`.
**Produces:** a "New Folder" toolbar button reusing Task 3's prompt.

- [ ] **1** Add:

```qml
    function beginMkdir(): void {
        root.promptMode = "mkdir";
        root.promptText = "";
    }
```

- [ ] **2** Extend `confirmPrompt()`'s branch:

```qml
        } else if (root.promptMode === "mkdir") {
            root.runOperation(Operations.mkdirArgv(FilesMath.join(root.activePane.path, root.promptText)));
        }
```

- [ ] **3** Add to the toolbar, next to "Rename":

```qml
                Text {
                    text: "New Folder"
                    color: Theme.fg
                    font.family: Theme.fontUi

                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.beginMkdir()
                    }
                }
```

- [ ] **4** `nix run .#nix-lint`
      Expected: green

- [ ] **5** `qs ipc call files openPath /tmp`, click "New Folder", type
      `probe-mkdir`, press Enter
      Expected: `/tmp/probe-mkdir` exists as a directory and appears in
      the pane immediately

- [ ] **6** `rmdir /tmp/probe-mkdir`

- [ ] **7** `git add nix/home/quickshell/qml/files/Files.qml`
      `git commit -m "feat: create folders from the file manager"`

---

### Task 5: Trash

**Files:**
- Modify: `nix/home/quickshell/qml/files/Files.qml`
- Modify: `nix/home/quickshell/default.nix:172-186`

**Produces:** a "Trash" toolbar button; `gio` on `PATH` via `pkgs.glib`,
which nothing in this shell configuration pulled in before this task.

- [ ] **1** Add:

```qml
    function trashSelected(): void {
        const pane = root.activePane;
        if (!pane.selected)
            return;

        root.runOperation(Operations.trashArgv(FilesMath.join(pane.path, pane.selected.name)));
    }
```

- [ ] **2** Add to the toolbar:

```qml
                Text {
                    text: "Trash"
                    color: Theme.red
                    font.family: Theme.fontUi

                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.trashSelected()
                    }
                }
```

- [ ] **3** In `nix/home/quickshell/default.nix`, add `pkgs.glib` to
      `home.packages` (`:172-186`), next to `pkgs.awww`:

```nix
      # gio trash (files/operations.js's trashArgv) needs `gio` on PATH.
      # glib, not trash-cli: it is already pulled in by this desktop's own
      # GTK closure, and both honour the same .Trash-$uid convention on a
      # removable filesystem's own top level.
      pkgs.glib
```

- [ ] **4** `nix run .#nix-lint`
      Expected: green

- [ ] **5** `which gio` after a home-manager switch onto this branch, or
      `nix build .#homeConfigurations.<user>.activationPackage` if a dry
      build is preferred first
      Expected: resolves to a store path under `glib`

- [ ] **6** `touch $HOME/probe-trash.txt`.
      `qs ipc call files openPath $HOME`, select `probe-trash.txt`, click
      "Trash"
      Expected: `probe-trash.txt` is gone from the pane and from
      `$HOME`, and `ls ~/.local/share/Trash/files/ | grep probe-trash.txt`
      finds it — recoverable, not `rm`'d

- [ ] **7** `rm -f ~/.local/share/Trash/files/probe-trash.txt`

- [ ] **8** `git add nix/home/quickshell/qml/files/Files.qml nix/home/quickshell/default.nix`
      `git commit -m "feat: trash entries with gio"`
