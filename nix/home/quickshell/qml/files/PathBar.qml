// The breadcrumb bar: where you are, one clickable component at a time.
//
// It spans the whole window between the tab strip and the body rather than
// sitting inside the pane, because it describes the tab, not the pane —
// the sidebar's selection changes it too. A band with its own fill, one
// shade off both neighbours, so it separates the strip above from the body
// below instead of being a line of text floating over the same ground.
//
// The crumbs centre on the bar and the arrows anchor to its left edge,
// rather than both living in one row. In a row the path would start
// wherever the arrows happened to end and drift left and right as Back and
// Forward change width; anchored separately, the arrows stay put and the
// path stays centred on the window whatever the history is doing.
//
// Crumb paths come from FilesMath.crumbsFor, which is unit-tested: a
// breadcrumb that is one slash out sends a click somewhere the user did
// not point at, and nothing on screen would show it was wrong.
//
// A crumb click opens CrumbMenu rather than navigating straight there —
// see browse() below and Files.qml's own wiring of it — so the click still
// reaches the right directory, just one row further in.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import "files.js" as FilesMath
import ".."

Rectangle {
    id: root

    required property string path
    required property bool canBack
    required property bool canForward

    readonly property var crumbs: FilesMath.crumbsFor(root.path)

    signal navigate(string path)
    signal back()
    signal forward()
    // Window coordinates, because the dropdown this opens mounts on the
    // window rather than inside this bar: a popup clipped to the bar could
    // not overhang its bottom edge the way Menu.qml's already does.
    signal browse(string path, real x, real y)

    implicitHeight: Theme.filesRowHeight + Theme.filesPadding
    // Pinned to bg rather than lifted to the lighter `raised` token: below,
    // Pane fills with Theme.selection, and bg reads at a solid ~1.74:1
    // against it — moving this bar any lighter (raised or selection
    // itself) would collapse that seam back toward 1:1 instead. bg also
    // keeps this bar's own breadcrumb trail and nav arrows, both
    // Theme.muted/Theme.dim by default, at a healthy contrast. The seam
    // against the tab strip above is the one casualty of staying here —
    // see Tabs.qml's own comment on why that side was not lightened either.
    color: Theme.bg

    RowLayout {
        id: nav

        anchors.left: parent.left
        anchors.leftMargin: Theme.filesRowInset
        anchors.verticalCenter: parent.verticalCenter

        spacing: 10

        // Back and Forward are dimmed rather than hidden at the ends of the
        // history: an arrow that vanishes takes the other one's position
        // with it, and the pair would shuffle sideways on every navigation.
        Text {
            text: "\u{F004D}"
            color: {
                if (!root.canBack)
                    return Theme.dim;

                return backArea.containsMouse ? Theme.accent : Theme.muted;
            }
            font.family: Theme.fontUi
            font.pixelSize: Theme.filesIconSize

            MouseArea {
                id: backArea

                anchors.fill: parent
                anchors.margins: -Theme.filesHoverPadWide
                enabled: root.canBack
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.back()
            }
        }

        Text {
            text: "\u{F0054}"
            color: {
                if (!root.canForward)
                    return Theme.dim;

                return forwardArea.containsMouse ? Theme.accent : Theme.muted;
            }
            font.family: Theme.fontUi
            font.pixelSize: Theme.filesIconSize

            MouseArea {
                id: forwardArea

                anchors.fill: parent
                anchors.margins: -Theme.filesHoverPadWide
                enabled: root.canForward
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.forward()
            }
        }

        Text {
            text: "\u{F005D}"
            color: upArea.containsMouse ? Theme.accent : Theme.muted
            font.family: Theme.fontUi
            font.pixelSize: Theme.filesIconSize

            MouseArea {
                id: upArea

                anchors.fill: parent
                anchors.margins: -Theme.filesHoverPadWide
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.navigate(FilesMath.parentOf(root.path))
            }
        }
    }

    // Centred on the bar, not on the space left over beside the arrows, so
    // the path sits under the middle of the window. Clipped to the gap
    // between the arrows and the right edge: a deep enough path would
    // otherwise run under the arrows it is centred against.
    Item {
        anchors.left: nav.right
        anchors.leftMargin: Theme.filesRowInset
        anchors.right: parent.right
        anchors.rightMargin: Theme.filesRowInset
        anchors.verticalCenter: parent.verticalCenter

        implicitHeight: crumbs.implicitHeight
        height: crumbs.implicitHeight
        clip: true

        RowLayout {
            id: crumbs

            anchors.centerIn: parent
            spacing: 4

            Repeater {
                model: root.crumbs

                delegate: RowLayout {
                    id: crumb

                    required property var modelData
                    required property int index

                    readonly property bool last: crumb.index === root.crumbs.length - 1

                    spacing: 4

                    // The separator leads each crumb except the first, so
                    // root does not get a slash in front of the slash it
                    // already is.
                    Text {
                        text: "\u{F0142}"
                        color: Theme.dim
                        font.family: Theme.fontUi
                        font.pixelSize: Theme.filesIconSize
                        visible: crumb.index > 0
                    }

                    Text {
                        text: crumb.modelData.label
                        // The last crumb is where you actually are, so it
                        // gets the emphasis and the rest read as the trail.
                        color: {
                            if (crumbArea.containsMouse)
                                return Theme.accent;

                            return crumb.last ? Theme.fg : Theme.muted;
                        }
                        font.family: Theme.fontUi
                        font.pixelSize: Theme.fontSize
                        font.bold: crumb.last

                        MouseArea {
                            id: crumbArea

                            anchors.fill: parent
                            anchors.margins: -Theme.filesHoverPad
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            // A single click used to navigate straight
                            // there; it opens the dropdown instead now, so
                            // navigating this crumb's own directory is one
                            // click further in, through that dropdown's own
                            // first row.
                            onClicked: (mouse) => {
                                const at = crumbArea.mapToItem(null, mouse.x, mouse.y);
                                root.browse(crumb.modelData.path, at.x, at.y);
                            }
                        }
                    }
                }
            }
        }
    }
}
