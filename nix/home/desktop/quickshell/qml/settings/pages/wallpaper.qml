// The Wallpaper settings page: mode/output/fill-colour controls above a
// thumbnail grid over Wallpapers/. Loaded by Settings.qml through a
// `Loader { source: "pages/wallpaper.qml" }` (the same lowercase-filename-
// by-source-URL idiom pages/security.qml uses, for the identical reason —
// this filename cannot be a QML type name).
//
// root.picker is required, not owned: wallpaper/Picker.qml is the ONE
// instance shell.qml keeps alive at the top level, because Rotation.qml's
// hourly pick and `qs ipc call wallpaper apply` both drive it whether or
// not this page is even mounted. Settings.qml's Loader wires
// `onLoaded: item.picker = picker` rather than this file instantiating its
// own Picker, so a click here runs through the exact same apply queue,
// output-state FileView and accent-retint Canvas Picker.qml already owns —
// never a second copy of any of them.
//
// mode/output/fill colour used to be m/o/c keyboard cycles on the
// standalone overlay's own Chrome; this page has no window-level key
// handler to carry those on, so they are direct-pick Select rows instead
// (controls/Select.qml, the same control Settings.qml's own "select"-typed
// rows already use) — arguably better than cycling, since every option is
// visible at once rather than stepped through blind.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import "../../wallpaper"
import "../../wallpaper/picker.js" as PickerLogic
import "../../launcher/preview.js" as PreviewMath
import "../.."
import "../../common"
import ".."
import "../controls"

ColumnLayout {
    id: root

    required property Picker picker

    spacing: Theme.settingsGroupGap

    // Mirrors the standalone overlay's own open(): reload the Wallpapers/
    // listing and start the cursor at the first tile. Runs once per mount,
    // since Settings' Loader tears this whole item down on every exit from
    // the Wallpaper page — a directory that changed while Settings sat open
    // elsewhere must not show as this page's stale first read.
    Component.onCompleted: {
        root.picker.reload();
        root.picker.selected = 0;
    }

    ColumnLayout {
        Layout.fillWidth: true

        spacing: Theme.settingsRowGap

        SettingsRow {
            title: "Mode"
            description: "How a picked wallpaper fills the screen."

            Select {
                width: 160
                options: ["fill", "stretch", "fit", "center", "tile"].map(m => ({ label: m, value: m }))
                value: root.picker.mode
                onActivated: value => root.picker.mode = value
            }
        }

        SettingsRow {
            title: "Output"
            description: "Apply to every monitor, or just one."

            Select {
                width: 160
                options: ["*"].concat(root.picker.outputNames).map(o => ({ label: o, value: o }))
                value: root.picker.output
                onActivated: value => root.picker.selectOutput(value)
            }
        }

        SettingsRow {
            title: "Fill color"
            description: "Letterbox colour for a mode narrower than the screen."

            Select {
                width: 160
                options: PickerLogic.COLOR_PALETTE.map(c => ({ label: c, value: c }))
                value: root.picker.fillColor
                onActivated: value => root.picker.fillColor = value
            }
        }

        // The keyboard 'r' restore on the standalone overlay, as a button:
        // every output that has ever had a wallpaper applied to it by name
        // gets its own recorded path/mode/fillColor back (Picker.qml's own
        // restore(), unchanged).
        SettingsRow {
            title: "Restore"
            description: "Replay every output's own last-applied wallpaper."
            clickable: true

            onClicked: root.picker.restore()

            Text {
                text: "\u{F0453}"
                color: Theme.muted

                font.family: Theme.fontUi
                font.pointSize: Theme.settingsRowTitleFontSize
            }
        }
    }

    GridView {
        id: grid

        Layout.fillWidth: true
        Layout.fillHeight: true

        clip: true
        cellWidth: 200
        cellHeight: 130

        model: root.picker.files
        currentIndex: root.picker.selected
        highlightFollowsCurrentItem: true

        delegate: Rectangle {
            id: cell

            required property string modelData
            required property int index

            width: grid.cellWidth - 8
            height: grid.cellHeight - 8

            radius: 6
            color: Theme.bgDark

            EdgeStrip {
                edge: "top"
                active: cell.index === root.picker.selected
                thickness: 2
            }

            // Capped at 320x200 (sourceSize, not the cell's own display
            // size): the old preview cache's own bound, kept so a
            // directory of a few hundred photos never decodes at full
            // resolution just to show a tile.
            Image {
                anchors.fill: parent
                anchors.margins: 2

                source: PreviewMath.fileUrl(cell.modelData)
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                sourceSize.width: 320
                sourceSize.height: 200
            }

            MouseArea {
                anchors.fill: parent

                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    root.picker.selected = cell.index;
                    root.picker.applySelected();
                }
            }
        }
    }
}
