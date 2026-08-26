// The on-screen display for the media keys, and the actions behind them.
//
// This replaces rust/dots-osd, which never drew anything: it actuated the
// hardware and then sent a desktop notification, borrowing dunst's popup as a
// rendering surface. That is why it needed the x-dunst-stack-tag hint, so that
// holding a volume key replaced one popup instead of stacking thirty. A shell
// with its own surface needs none of that here, because the level is one
// property being overwritten.
//
// The hint has not gone away, though: `dots-osd watch` still sends tagged
// alerts, so the notification server honours it. See Notifications.qml.
//
// Volume and mute go through Pipewire directly instead of spawning wpctl twice
// per keypress, as dots-osd's own module comment complained about. Brightness
// still shells out, because there is no brightness service to talk to.
//
// Placement is a deliberate change. dots-osd appeared top-right because that is
// where dunst put notifications; an OSD belongs in the middle of the screen,
// which is now possible because this owns its window.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Services.Pipewire
import ".."

Scope {
    id: root

    // dots-osd's STEP, as a fraction. Pipewire volume is 0..1 at unity.
    readonly property real step: 0.05

    // dots-osd's VOLUME_LIMIT: the sink takes software boost past unity, and
    // 1.5 is where it stopped because further amplifies less than it distorts.
    readonly property real volumeLimit: 1.5

    property string glyph: ""
    property string label: ""

    // Negative means "no bar", for the toggles that have no level.
    property real level: -1

    readonly property var sink: Pipewire.defaultAudioSink
    readonly property var source: Pipewire.defaultAudioSource

    readonly property var focusedScreen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) ?? null

    function present(glyph: string, label: string, level: real): void {
        root.glyph = glyph;
        root.label = label;
        root.level = level;
        hideTimer.restart();
        window.visible = true;
    }

    function volumeGlyph(): string {
        if (!root.sink?.audio || root.sink.audio.muted)
            return "\u{F026}";

        return root.sink.audio.volume > 0.5 ? "\u{F028}" : "\u{F027}";
    }

    function showVolume(): void {
        const audio = root.sink?.audio;
        if (!audio)
            return;

        // The bar tracks volume against unity, not against the boost ceiling.
        // Scaling by 1.5 would draw 60% volume as a bar at 40%, disagreeing
        // with the number printed next to it. Past unity the bar simply sits
        // full and the label carries the boost, which is what dots-osd did by
        // sending the raw percentage as the `value` hint.
        const percent = Math.round(audio.volume * 100);
        root.present(root.volumeGlyph(), audio.muted ? `Muted at ${percent}%` : `${percent}%`, audio.volume);
    }

    function nudgeVolume(delta: real): void {
        const audio = root.sink?.audio;
        if (!audio)
            return;

        audio.volume = Math.max(0, Math.min(root.volumeLimit, audio.volume + delta));
        root.showVolume();
    }

    // Pipewire objects only stay live while something binds them. Without the
    // tracker the sink reads back stale, which is the sort of bug that looks
    // like the volume key not working.
    PwObjectTracker {
        objects: [root.sink, root.source]
    }

    IpcHandler {
        target: "osd"

        function volumeUp(): void {
            root.nudgeVolume(root.step);
        }

        function volumeDown(): void {
            root.nudgeVolume(-root.step);
        }

        function volumeMute(): void {
            const audio = root.sink?.audio;
            if (!audio)
                return;

            audio.muted = !audio.muted;
            root.showVolume();
        }

        function micToggle(): void {
            const audio = root.source?.audio;
            if (!audio)
                return;

            audio.muted = !audio.muted;
            root.present(audio.muted ? "\u{F131}" : "\u{F130}", audio.muted ? "Microphone muted" : "Microphone live", -1);
        }

        function brightnessUp(): void {
            brightness.command = ["brightnessctl", "-m", "set", "5%+"];
            brightness.running = true;
        }

        function brightnessDown(): void {
            brightness.command = ["brightnessctl", "-m", "set", "5%-"];
            brightness.running = true;
        }

        function touchpadToggle(): void {
            touchpadDevices.running = true;
        }

        // Narrower than the name suggests, exactly as dots-osd's was: muting
        // the source is something a session can do for itself, cutting power to
        // a webcam is not. dots-osd went further and named any process holding
        // the camera open, so that "privacy on" was never mistaken for "the
        // camera is off". That check is not ported yet.
        function privacyToggle(): void {
            const audio = root.source?.audio;
            if (!audio)
                return;

            audio.muted = !audio.muted;
            root.present(audio.muted ? "\u{F132}" : "\u{F130}", audio.muted ? "Privacy on, microphone muted" : "Privacy off, microphone live", -1);
        }
    }

    // brightnessctl -m prints device,class,current,percent,max, so the same
    // call that makes the change also reports where it landed. Reading it back
    // with a second process would be a race against the next keypress.
    Process {
        id: brightness

        stdout: StdioCollector {
            onStreamFinished: {
                const fields = this.text.trim().split(",");
                if (fields.length < 4)
                    return;

                const percent = parseInt(fields[3].replace("%", ""), 10);
                if (Number.isNaN(percent))
                    return;

                root.present("\u{F185}", `${percent}%`, percent / 100);
            }
        }
    }

    // Hyprland cannot report a device's enabled flag back, so dots-osd kept the
    // answer in a runtime file. The same trick is used here, through a marker
    // whose presence means "off".
    Process {
        id: touchpadDevices

        command: ["hyprctl", "devices", "-j"]

        stdout: StdioCollector {
            onStreamFinished: {
                let devices;
                try {
                    devices = JSON.parse(this.text);
                } catch (e) {
                    return;
                }

                const touchpad = (devices.mice ?? []).find(m => m.name.includes("touchpad"));
                if (!touchpad)
                    return;

                const enabling = !root.touchpadDisabled;
                root.touchpadDisabled = enabling;

                touchpadApply.command = ["hyprctl", "eval", `hl.device({ name = "${touchpad.name}", enabled = ${!enabling} })`];
                touchpadApply.running = true;

                root.present("\u{F109}", enabling ? "Touchpad disabled" : "Touchpad enabled", -1);
            }
        }
    }

    // hyprctl keyword is a silent no-op under Hyprland 0.55+'s Lua parser, so
    // the change goes through eval and the DSL, the same route hyprmon takes.
    Process {
        id: touchpadApply
    }

    property bool touchpadDisabled: false

    Timer {
        id: hideTimer

        interval: 1500

        onTriggered: window.visible = false
    }

    PanelWindow {
        id: window

        screen: root.focusedScreen
        color: "transparent"
        visible: false

        // Anchored to the bottom only, which layer-shell centres horizontally.
        anchors.bottom: true

        // Quickshell ships no qmltypes entry for PanelWindow's Margins, so the
        // linter cannot resolve this even though it binds fine. A comment line
        // may not start with the linter's own name or it is read as a
        // directive, which is its own small trap.
        // qmllint disable unqualified unresolved-type
        margins.bottom: 120
        // qmllint enable unqualified unresolved-type

        exclusiveZone: 0

        implicitWidth: 280
        implicitHeight: 96

        // Nothing here is clickable, and an unmasked overlay would swallow
        // clicks aimed at whatever is behind it.
        mask: Region {}

        Rectangle {
            anchors.fill: parent

            radius: 16
            color: Qt.alpha(Theme.bgDark, 0.92)
            border.width: 2
            border.color: Theme.border

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 16

                spacing: 10

                RowLayout {
                    Layout.fillWidth: true

                    spacing: 12

                    Text {
                        text: root.glyph
                        color: Theme.accent

                        font.family: Theme.fontUi
                        font.pixelSize: 26
                    }

                    Text {
                        Layout.fillWidth: true

                        text: root.label
                        color: Theme.fg

                        font.family: Theme.fontUi
                        font.pixelSize: 15
                        font.bold: true

                        elide: Text.ElideRight
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 6

                    visible: root.level >= 0

                    radius: 3
                    color: Theme.selection

                    Rectangle {
                        width: parent.width * Math.max(0, Math.min(1, root.level))
                        height: parent.height

                        radius: parent.radius
                        color: Theme.accent
                    }
                }
            }
        }
    }
}
