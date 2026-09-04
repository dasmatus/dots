# Devices & Files 1: Browser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use
> superpowers:subagent-driven-development or superpowers:executing-plans.

**Goal:** A real, single-pane file manager: browse, open, eject. Every dead
end the spec's Why section names, the nautilus keybind, the cheatsheet
entry, the launcher's directory hits, now lands here instead of nowhere.
**Architecture:** `qml/files/Files.qml`, a `Scope` holding one
`FloatingWindow`. Not `PanelWindow`, since this is a tiled application
window, not a dismiss-on-click overlay, toggled the same way the launcher
is. One `Pane.qml` lists a directory via `ls -1Ap` as direct argv. A
`Sidebar.qml` lists `Devices.devices` (built in Plan 0) and reuses its
`requestOpen` signal for navigation, the same signal the launcher's device
rows already call.
**Tech Stack:** Quickshell 0.3, Qt 6.11, coreutils `ls`/`xdg-open`, QtTest.
**Spec:** `docs/superpowers/specs/2026-08-27-devices-files-design.md`

## Global Constraints
- `Files.qml`'s window is a `FloatingWindow`. Not `PanelWindow`: this
  surface is meant to be tiled and alt-tabbed to like any other
  application, unlike every other overlay in this tree.
- Directory listing runs `ls` as a direct argv array, never through
  `sh -c`. There is no shell in this feature's listing path at all, unlike
  `preview.js`, which needed one only for its `[ -d ... ]` branch.
- `Devices.requestOpen(path)` is the single navigation entrypoint into this
  module. The launcher's device rows (Plan 0), the launcher's directory
  hits (Task 5 below) and the sidebar (Task 3) all call it; `Files.qml` is
  the only thing that ever connects to it.
- `openPath(path: string)` on the `files` IPC target is this feature's one
  deliberately-proven argument-taking IPC call, proven with a literal
  `qs ipc call files openPath <path>`, not assumed from the wallpaper
  picker's own unexercised `apply(path, output, mode)`.
- `qmllint --max-warnings 0` (`nix run .#nix-lint`), unchanged gate.

---

### Task 1: `files.js`, `Pane.qml`, `Files.qml`, one window, one pane

**Files:**
- Create: `nix/home/desktop/quickshell/qml/files/files.js`
- Create: `tests/qml/tst_files.qml`
- Create: `nix/home/desktop/quickshell/qml/files/Pane.qml`
- Create: `nix/home/desktop/quickshell/qml/files/Files.qml`
- Modify: `nix/home/desktop/quickshell/qml/shell.qml`

**Produces:** `files.js` exporting `parseListing(text)`, `join(dir, name)`,
`parentOf(path)`. `Pane`'s `path` property and `navigate(string path)`
signal. `Files`'s `open()`/`close()`/`toggle()` and its `path` property,
which `Connections { target: Devices }` already drives, so every
`Devices.requestOpen()` call left dormant by Plan 0 Task 4 starts actually
opening something the moment this task lands.

- [ ] **1** Write `tests/qml/tst_files.qml`:

```qml
// Pure listing-and-path arithmetic for Pane.qml, driven with captured
// `ls -1Ap --group-directories-first` output. No Process, no filesystem,
// no compositor.
import QtQuick
import QtTest
import "../../nix/home/desktop/quickshell/qml/files/files.js" as Files

TestCase {
    name: "Files"

    function test_parselisting_strips_the_trailing_slash_ls_p_appends() {
        const entries = Files.parseListing("Documents/\nDownloads/\nreadme.txt\n");

        compare(entries.length, 3);
        compare(entries[0].name, "Documents");
        compare(entries[0].isDir, true);
        compare(entries[2].name, "readme.txt");
        compare(entries[2].isDir, false);
    }

    function test_parselisting_drops_blank_lines() {
        compare(Files.parseListing("\n\n").length, 0);
    }

    function test_join_handles_the_root_directory() {
        compare(Files.join("/", "home"), "/home");
        compare(Files.join("/home/matus", "Documents"), "/home/matus/Documents");
    }

    function test_parentof_stops_at_root() {
        compare(Files.parentOf("/"), "/");
        compare(Files.parentOf("/home"), "/");
        compare(Files.parentOf("/home/matus"), "/home");
    }
}
```

- [ ] **2** Run QtTest
      Expected: FAIL, "files/files.js: no such file"

- [ ] **3** Write `nix/home/desktop/quickshell/qml/files/files.js`:

```js
// Pure directory-listing helpers for Pane.qml. Split out so
// tests/qml/tst_files.qml can drive them with captured `ls -1Ap` output
// and no Process, filesystem or compositor anywhere near the test.
.pragma library

// `-p` marks a directory with a trailing slash; this is the only place
// that convention is interpreted, so Pane.qml's own entries carry a plain
// isDir boolean instead.
function parseListing(text) {
    return text.split("\n").filter(line => line !== "").map(raw => {
        const isDir = raw.endsWith("/");
        return { name: isDir ? raw.slice(0, -1) : raw, isDir: isDir };
    });
}

function join(dir, name) {
    return dir.replace(/\/$/, "") + "/" + name;
}

function parentOf(path) {
    if (path === "/")
        return "/";

    const cut = path.lastIndexOf("/");
    return cut <= 0 ? "/" : path.slice(0, cut);
}
```

- [ ] **4** Run QtTest again
      Expected: PASS, 4/4

- [ ] **5** Write `nix/home/desktop/quickshell/qml/files/Pane.qml`:

```qml
// One directory's listing. `ls -1Ap --group-directories-first` runs as
// direct argv with no shell. Nothing on this path interpolates a path
// into a command string, so there is nothing here for a shell to need.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "files.js" as FilesMath
import ".."

Item {
    id: root

    required property string path

    signal navigate(string path)

    property var entries: []

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
                    onClicked: root.navigate(FilesMath.parentOf(root.path))
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
                color: "transparent"

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
                    onClicked: root.activate(row.modelData)
                }
            }
        }
    }
}
```

- [ ] **6** Write `nix/home/desktop/quickshell/qml/files/Files.qml`:

```qml
// The file manager's outer shell: one FloatingWindow around one Pane. The
// second Pane and the Sidebar's write operations arrive in later plans;
// Sidebar itself (Task 3) is the next task in this one.
//
// Devices.requestOpen(path) is the single way anything outside this file
// tells it where to go: the launcher's device rows (Plan 0), the
// launcher's directory hits and this window's own Sidebar (both later in
// this plan) all call it, and this Connections block is the only listener.
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "../services"

Scope {
    id: root

    property string path: Quickshell.env("HOME")

    function open(): void {
        window.visible = true;
    }

    function close(): void {
        window.visible = false;
    }

    function toggle(): void {
        window.visible = !window.visible;
    }

    Connections {
        target: Devices

        function onRequestOpen(path) {
            root.path = path;
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
    }

    FloatingWindow {
        id: window

        visible: false
        implicitWidth: 900
        implicitHeight: 600

        Pane {
            anchors.fill: parent

            path: root.path
            onNavigate: (path) => root.path = path
        }
    }
}
```

- [ ] **7** In `shell.qml`, add `import "files"` alongside the other
      directory imports, and instantiate `Files {}` next to `Settings {}`.
      Extend the header comment's single-instance list ("The launcher,
      cheatsheet, settings form, wallpaper picker and monitor arrange
      surface are single instances too") to also name the file manager.

- [ ] **8** `nix run .#nix-lint`
      Expected: green

- [ ] **9** `qs ipc call files toggle`
      Expected: a 900x600 window opens listing `$HOME`'s real contents,
      directories prefixed `▸`; clicking a directory navigates into it and
      updates the path label; clicking `↑` at the root of `$HOME` goes to
      its parent

- [ ] **10** With the real USB disk still mounted from Plan 0, open the
      launcher (SUPER+Space), type its label, and activate the device row
      Expected: the file manager opens (or is reused if already open) and
      navigates to the disk's mountpoint. This is Plan 0 Task 4's
      `Devices.requestOpen()` call, dormant until now, working for the
      first time

- [ ] **11** `git add nix/home/desktop/quickshell/qml/files/files.js nix/home/desktop/quickshell/qml/files/Pane.qml nix/home/desktop/quickshell/qml/files/Files.qml nix/home/desktop/quickshell/qml/shell.qml tests/qml/tst_files.qml`
      `git commit -m "feat: add a single-pane file manager"`

---

### Task 2: `openPath`, the proven argument-taking IPC call

**Files:** Modify `nix/home/desktop/quickshell/qml/files/Files.qml`.
**Produces:** `openPath(path: string)` on the `files` IPC target.

- [ ] **1** Add to the `IpcHandler` block:

```qml
        function openPath(path: string): void {
            root.path = path;
            root.open();
        }
```

- [ ] **2** `nix run .#nix-lint`
      Expected: green

- [ ] **3** `mkdir -p /tmp/probe-openpath && touch /tmp/probe-openpath/proof.txt`
      `qs ipc call files openPath /tmp/probe-openpath`
      Expected: the file manager opens showing `/tmp/probe-openpath` with
      `proof.txt` listed. This is the first time in this repo's history a
      string-argument `IpcHandler` function has been called from outside
      the process and observed to work, closing the gap the spec's
      Decisions section names against `wallpaper`'s `apply()`

- [ ] **4** `rm -rf /tmp/probe-openpath`

- [ ] **5** `git add nix/home/desktop/quickshell/qml/files/Files.qml`
      `git commit -m "feat: add files openPath to the files IPC target"`

---

### Task 3: Sidebar, devices, Home, and eject

**Files:**
- Create: `nix/home/desktop/quickshell/qml/files/Sidebar.qml`
- Modify: `nix/home/desktop/quickshell/qml/files/Files.qml`

**Produces:** a device list down the left of the window, click-to-navigate,
one eject control per row.

- [ ] **1** Write `nix/home/desktop/quickshell/qml/files/Sidebar.qml`:

```qml
// Home plus every currently-mounted device. Navigation reuses
// Devices.requestOpen, the same signal the launcher's device rows and
// directory hits call, so Files.qml needs no extra wiring for this file
// to work. Eject is a direct in-process call on the singleton instead: it
// is an immediate action, not something another surface needs to react to.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import "../services"
import ".."

ColumnLayout {
    id: root

    spacing: 4

    Text {
        text: "Home"
        color: Theme.fg
        font.family: Theme.fontUi

        MouseArea {
            anchors.fill: parent
            onClicked: Devices.requestOpen(Quickshell.env("HOME"))
        }
    }

    Repeater {
        model: Devices.devices

        delegate: RowLayout {
            id: entry

            required property var modelData

            Layout.fillWidth: true

            Text {
                Layout.fillWidth: true
                text: entry.modelData.label
                color: Theme.fg
                font.family: Theme.fontUi
                elide: Text.ElideRight

                MouseArea {
                    anchors.fill: parent
                    onClicked: Devices.requestOpen(entry.modelData.mountPoint)
                }
            }

            Text {
                text: "⏏"
                color: Theme.muted
                font.family: Theme.fontUi

                MouseArea {
                    anchors.fill: parent
                    onClicked: Devices.eject(entry.modelData.path)
                }
            }
        }
    }
}
```

- [ ] **2** In `Files.qml`, replace the bare `Pane` child of `FloatingWindow`
      with a `RowLayout` holding a `Sidebar` and the `Pane` (needs
      `import QtQuick.Layouts` added):

```qml
        RowLayout {
            anchors.fill: parent
            spacing: 0

            Sidebar {
                Layout.fillHeight: true
                Layout.preferredWidth: 200
            }

            Pane {
                Layout.fillWidth: true
                Layout.fillHeight: true

                path: root.path
                onNavigate: (path) => root.path = path
            }
        }
```

- [ ] **3** `nix run .#nix-lint`
      Expected: green

- [ ] **4** `qs ipc call files toggle`
      Expected: the sidebar lists "Home" and the mounted USB disk's label;
      clicking the disk navigates the pane to its mountpoint

- [ ] **5** Click the disk's `⏏`
      Expected: `lsblk -J -b -o NAME,PATH` no longer lists `sda` or `sda1`
      at all. `power-off` removes the USB device node, not merely its
      mount, and the bar pill from Plan 0 goes back to hidden

- [ ] **6** Physically replug the disk
      Expected: it reappears, remounts and re-lists in the sidebar with no
      shell restart, proving `eject()` didn't leave the watcher in a state
      that only recovers on reload

- [ ] **7** `git add nix/home/desktop/quickshell/qml/files/Sidebar.qml nix/home/desktop/quickshell/qml/files/Files.qml`
      `git commit -m "feat: list and eject devices from the file manager sidebar"`

---

### Task 4: Repair the dead nautilus keybind and cheatsheet entry

**Files:**
- Modify: `nix/home/desktop/hyprland.nix:412-419`
- Modify: `nix/home/desktop/keybinds.nix:26-27`

**Produces:** SUPER+SHIFT+F opens the shell's own file manager; the
cheatsheet stops naming software that was never installed.

- [ ] **1** In `nix/home/desktop/hyprland.nix`, replace:

```nix
        # Nautilus directly (GNOME Files, services.gnome.core-apps). The
        # rofi-files.sh dmenu browser retired with the HyprTile conversion.
        {
          _args = [
            (lua ''mod .. " + SHIFT + F"'')
            (lua ''hl.dsp.exec_cmd("nautilus")'')
          ];
        }
```

  with:

```nix
        # The shell's own file manager (qml/files). Nautilus was never
        # installed (no services.gnome.core-apps anywhere in this tree),
        # so this bind did nothing from the day it was written until this.
        {
          _args = [
            (lua ''mod .. " + SHIFT + F"'')
            (lua ''hl.dsp.exec_cmd("qs ipc call files toggle")'')
          ];
        }
```

- [ ] **2** In `nix/home/desktop/keybinds.nix`, change line 27 from
      `desc = "File manager (Nautilus)";` to `desc = "File manager";`

- [ ] **3** `grep -rn nautilus nix/home/`
      Expected: no hits

- [ ] **4** `nix run .#nix-lint`
      Expected: green (this is a flake-eval check on `hyprland.nix` and
      `keybinds.nix`, not a QML one, a Lua-string or Nix syntax mistake in
      either file fails it)

- [ ] **5** `nix build .#quickshell-config && grep -n "File manager" result/cheatsheet/keybinds.json`
      Expected: one match, and `grep -c Nautilus result/cheatsheet/keybinds.json`
      returns 0

- [ ] **6** Press SUPER+SHIFT+F in a live session
      Expected: the file manager opens; SUPER+/ shows "File manager" with
      no mention of Nautilus

- [ ] **7** `git add nix/home/desktop/hyprland.nix nix/home/desktop/keybinds.nix`
      `git commit -m "fix: point SUPER+SHIFT+F at the shell's own file manager"`

---

### Task 5: Launcher, spawn row and the directory-hit fix

**Files:** Modify `nix/home/desktop/quickshell/qml/launcher/Providers.qml`.
**Produces:** an "Open File Manager" launcher row; `fileRows()`'s directory
branch stops calling `xdg-open`.

- [ ] **1** Add to `systemCommands`:

```qml
        {
            title: "Open File Manager",
            subtitle: "Browse files, dual-pane, SUPER+SHIFT+F",
            argv: ["qs", "ipc", "call", "files", "toggle"]
        }
```

- [ ] **2** Replace `fileRows()`'s `run` closure:

```qml
    function fileRows(text: string): var {
        return root.fileResults.map(path => ({
                    title: PreviewMath.displayName(path) + (PreviewMath.isDirectory(path) ? "/" : ""),
                    subtitle: path.replace(Quickshell.env("HOME"), "~"),
                    icon: "",
                    accessory: "open",
                    path: path,
                    run: () => PreviewMath.isDirectory(path) ? Devices.requestOpen(path) : Quickshell.execDetached(["xdg-open", path])
                }));
    }
```

- [ ] **3** `nix run .#nix-lint`
      Expected: green

- [ ] **4** Open the launcher (SUPER+Space), type "file"
      Expected: "Open File Manager" appears among the system rows;
      activating it opens (or focuses) the file manager

- [ ] **5** Type a few characters of a real subdirectory name under `$HOME`
      Expected: the directory hit shows a trailing `/`; activating it
      opens the file manager navigated into that directory. This is the
      fix this task exists for, replacing the `xdg-open` call that never
      had anywhere correct to resolve to

- [ ] **6** Type a few characters of a real file's name under `$HOME`
      Expected: activating it still runs `xdg-open` on the file, unchanged
      from before this task

- [ ] **7** `git add nix/home/desktop/quickshell/qml/launcher/Providers.qml`
      `git commit -m "feat: open directory hits and add a file manager launcher row"`
