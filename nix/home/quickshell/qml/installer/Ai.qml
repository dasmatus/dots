// app.rs::Screen::Ai — three toggles over settings.aiClaude/aiCodex/aiOllama
// (bridged to options.dots.ai.* by nix/modules/dots.nix), all defaulting on.
// Up/Down moves the cursor, Space flips the toggle under it, Enter commits
// and continues, Esc returns to GitEmail — the same four keys app.rs wires.
//
// Local `claude`/`codex`/`ollama` properties mirror `cfg.aiClaude` et al.
// rather than toggling the shared `cfg` object's fields directly: `cfg` is a
// plain JS object passed by reference, and mutating one of its fields in
// place raises no QML property-change signal, so the checkbox glyph below
// would never repaint. These are real QML properties instead, and
// `commitAndNext` is what writes them back onto `cfg` — once, on the way out,
// the same moment app.rs's Enter arm is the only one that matters to
// settings_nix.
pragma ComponentBehavior: Bound

import QtQuick
import ".."

Frame {
    id: root

    required property var cfg
    property int selected: 0
    property bool claude: cfg.aiClaude
    property bool codex: cfg.aiCodex
    property bool ollama: cfg.aiOllama

    readonly property var labels: ["Claude Code", "Codex CLI", "Ollama"]

    signal next()
    signal back()

    title: "AI tooling"
    hint: "Up/Down to move · Space to toggle · Enter to continue · Esc to go back"

    onActivated: capture.forceActiveFocus()

    function valueAt(i) {
        return i === 0 ? claude : i === 1 ? codex : ollama;
    }

    function toggleAt(i) {
        if (i === 0)
            claude = !claude;
        else if (i === 1)
            codex = !codex;
        else
            ollama = !ollama;
    }

    function commitAndNext() {
        cfg.aiClaude = claude;
        cfg.aiCodex = codex;
        cfg.aiOllama = ollama;
        next();
    }

    Item {
        id: capture

        width: parent.width
        height: list.height
        focus: true

        Keys.onUpPressed: root.selected = Math.max(root.selected - 1, 0)
        Keys.onDownPressed: root.selected = Math.min(root.selected + 1, root.labels.length - 1)
        Keys.onSpacePressed: root.toggleAt(root.selected)
        Keys.onReturnPressed: root.commitAndNext()
        Keys.onEnterPressed: root.commitAndNext()
        Keys.onEscapePressed: root.back()

        Column {
            id: list

            width: parent.width
            spacing: 8

            Repeater {
                model: root.labels

                delegate: Rectangle {
                    id: row

                    required property string modelData
                    required property int index

                    width: list.width
                    height: 40
                    radius: 6
                    color: index === root.selected ? Theme.selection : "transparent"
                    border.width: index === root.selected ? 1 : 0
                    border.color: Theme.accent

                    Row {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12

                        spacing: 12

                        Text {
                            anchors.verticalCenter: parent.verticalCenter

                            text: root.valueAt(row.index) ? "[x]" : "[ ]"
                            color: root.valueAt(row.index) ? Theme.green : Theme.muted

                            font.family: Theme.fontMono
                            font.pixelSize: Theme.fontSize
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter

                            text: row.modelData
                            color: Theme.fg

                            font.family: Theme.fontUi
                            font.pixelSize: Theme.fontSize
                        }
                    }
                }
            }
        }
    }
}
