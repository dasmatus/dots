// app.rs::Screen::DiskSelect — the manual multi-select picker, shown only
// when installer.qml's autodetectDisk() call could not pick a single fixed
// disk unambiguously. The chosen disks span one LVM volume group (disko.nix
// puts a PV on each), so the capacity gate below is on their combined size,
// matching app.rs's own span check.
pragma ComponentBehavior: Bound

import QtQuick
import ".."
import "disks.js" as Disks

Frame {
    id: root

    required property var cfg
    required property var disks

    property var picked: disks.map(() => false)
    property int selected: 0

    signal next()
    signal back()

    title: "Select target disk(s)"
    hint: "Up/Down to move · Space to toggle · Enter to confirm · Esc to go back"

    onActivated: capture.forceActiveFocus()

    function confirm() {
        const chosen = root.disks.filter((d, i) => root.picked[i]);
        if (chosen.length === 0) {
            root.error = "select at least one disk (Space to toggle)";
            return;
        }
        const need = Disks.requiredBytes(root.cfg.swapSizeGib);
        const total = chosen.reduce((sum, d) => sum + d.sizeBytes, 0);
        if (total < need) {
            const paths = chosen.map(d => d.path).join(", ");
            const totalGib = Math.floor(total / Disks.gib());
            root.error = `span too small: need ≥ ${Disks.requiredGib(root.cfg.swapSizeGib)} GiB across the VG (${Disks.espGib()}G ESP + ${root.cfg.swapSizeGib}G swap + ${Disks.rootGib()}G root), ${paths} total ${totalGib} GiB`;
            return;
        }
        root.cfg.disks = chosen.map(d => d.path);
        root.error = "";
        root.next();
    }

    Item {
        id: capture

        width: parent.width
        height: list.height
        focus: true

        Keys.onUpPressed: root.selected = Math.max(root.selected - 1, 0)
        Keys.onDownPressed: root.selected = Math.min(root.selected + 1, root.disks.length - 1)
        Keys.onSpacePressed: {
            const next = root.picked.slice();
            next[root.selected] = !next[root.selected];
            root.picked = next;
            root.error = "";
        }
        Keys.onReturnPressed: root.confirm()
        Keys.onEnterPressed: root.confirm()
        Keys.onEscapePressed: root.back()

        Column {
            id: list

            width: parent.width
            spacing: 8

            Repeater {
                model: root.disks

                delegate: Rectangle {
                    id: row

                    required property var modelData
                    required property int index

                    width: list.width
                    height: 48
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

                            text: root.picked[row.index] ? "[x]" : "[ ]"
                            color: root.picked[row.index] ? Theme.green : Theme.muted

                            font.family: Theme.fontMono
                            font.pixelSize: Theme.fontSize
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter

                            text: `${row.modelData.path}  ${Disks.humanSize(row.modelData)}` + (row.modelData.removable ? "  (removable)" : "") + (row.modelData.model ? "  " + row.modelData.model : "")
                            color: Theme.fg

                            font.family: Theme.fontMono
                            font.pixelSize: Theme.fontSize
                        }
                    }
                }
            }
        }
    }
}
