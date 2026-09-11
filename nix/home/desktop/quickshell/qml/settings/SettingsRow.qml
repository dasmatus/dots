// One row of the settings grammar: a title and a one-line description on
// the left, one control on the right. Every page built on this shell is
// meant to be nothing but a title, a description, and a stack of these.
// The task brief calls the row grammar "the important part" of the whole
// redesign, and this is that part, lifted into its own file so a page never
// hand-rolls a row of its own.
//
// A filled Rectangle per row, not a Text pair over a shared background: the
// source design separated rows with a 2px rule, which this shell's visual
// language discards outright (see the task brief's "visual language to
// discard entirely"). ColumnLayout's own `spacing` between these rows,
// Theme.settingsRowGap, 2px, draws the same seam by leaving the darker
// group background showing through instead, which is a fill difference
// rather than a line.
//
// Reaches only QtQuick, QtQuick.Layouts and Theme, no Quickshell type,
// which is what lets tests/qml/tst_settings_row_geometry.qml instantiate it
// directly instead of reading it as text, the same way
// tests/qml/tst_chrome_geometry.qml reaches Chrome.qml itself.
import QtQuick
import QtQuick.Layouts
import ".."

Rectangle {
    id: root

    property string title: ""
    property string description: ""

    // Extra search terms folded into the row's own match text but never
    // drawn. Settings.qml's search index reads this straight off the same
    // three properties search.js's row descriptors carry.
    property string keywords: ""

    // Structural: true for a row that only makes sense underneath some
    // parent toggle (an indented Wi-Fi network list under "Wi-Fi", say).
    // Fixed regardless of the parent's current value. A dependent row's
    // indent does not flicker in and out as the parent is flipped, only its
    // dimming and its controls' enabled state do.
    property bool dependent: false

    // The parent's CURRENT value. A caller binds this straight to whatever
    // toggle the row depends on; a plain `dependent: true` row with no
    // binding here defaults to enabled, which is deliberate: a row that
    // has not been wired to a real parent yet should not silently disable
    // itself.
    //
    // Assigned onto the row's own built-in `enabled`, which is what makes
    // "the controls disable" free: QtQuick already refuses pointer and key
    // input to a disabled item's children, so Toggle's MouseArea and every
    // other control's own input need not know their row was dimmed.
    property bool dependsOn: true
    enabled: root.dependsOn

    // The default property, so a caller's control is just a plain child:
    //     SettingsRow { title: "…"; Toggle { checked: … } }
    // Routed into a right-anchored Row rather than a bare Item so the
    // control sits flush against the row's own right edge regardless of
    // how narrow its natural width is. The alternative, anchoring each
    // control to its own parent from the outside, would leak this file's
    // internal structure into every page that builds a row.
    default property alias control: controlRow.data

    // Opt-in: a drill-in row (Settings.qml's "Proton" entry, which opens a
    // second page rather than editing a value) wants its WHOLE row to act
    // as the control, not just whatever sits in the control column. Most
    // rows have no reason to react to a click that missed their real
    // control, so this stays off unless a caller asks for it.
    property bool clickable: false

    signal clicked

    // The keyboard cursor's own highlight. A raised fill rather than
    // common/EdgeStrip.qml's accent line: the task brief reserves EdgeStrip
    // for marking the active SIDEBAR entry specifically, and reusing it here
    // too would give two unrelated kinds of "current" the same mark.
    property bool highlighted: false

    Layout.fillWidth: true

    // Not a fixed Theme.settingsRowHeight: Select.qml's control grows when
    // its option list opens, and a row that could not grow with it would
    // either clip the list or overlap the row underneath. Math.max keeps
    // every ordinary row (Toggle, Segmented, a bare label) at the palette's
    // own row height while still leaving room for the one control that asks
    // for more.
    implicitHeight: Math.max(Theme.settingsRowHeight, layout.implicitHeight + Theme.settingsRowPadding)

    radius: Theme.settingsRadius
    color: root.highlighted ? Theme.raised : Theme.bgDark

    // Dimming, not hiding: a dependent row whose parent is off still says
    // what it is and why it is unreachable, rather than vanishing and
    // leaving a gap the eye has to explain.
    opacity: root.dependsOn ? 1 : 0.45

    Behavior on opacity {
        NumberAnimation {
            duration: 120
        }
    }

    RowLayout {
        id: layout

        anchors.fill: parent
        anchors.leftMargin: Theme.settingsRowPadding + (root.dependent ? 24 : 0)
        anchors.rightMargin: Theme.settingsRowPadding
        anchors.topMargin: Theme.settingsRowPadding / 2
        anchors.bottomMargin: Theme.settingsRowPadding / 2

        spacing: 16

        ColumnLayout {
            Layout.fillWidth: true

            spacing: 2

            Text {
                Layout.fillWidth: true

                text: root.title
                color: Theme.fg
                elide: Text.ElideRight

                font.family: Theme.fontUi
                font.pointSize: Theme.settingsRowTitleFontSize
            }

            Text {
                Layout.fillWidth: true

                text: root.description
                visible: root.description !== ""
                color: Theme.muted
                elide: Text.ElideRight

                font.family: Theme.fontUi
                font.pointSize: Theme.settingsRowDescFontSize
            }
        }

        Item {
            id: controlHost

            Layout.preferredWidth: Theme.settingsControlColumn
            Layout.fillHeight: true

            // Bound rather than left at Item's own default of 0: a growing
            // control (Select.qml's option list opening) has to carry its
            // height into `layout`'s implicitHeight, or the row's own
            // Math.max formula above never learns the control got taller
            // and the option list clips against the row underneath.
            implicitHeight: controlRow.implicitHeight

            Row {
                id: controlRow

                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter

                spacing: 8
            }
        }
    }

    // Declared after `layout`, not before, and pinned behind it with `z`
    // rather than relying on that declaration order: Qt Quick already
    // favours the later sibling for overlapping input, but saying so with
    // `z` keeps this correct even if `layout` ever moves. Either way, a
    // real control inside `layout`, Toggle's own MouseArea, an option row
    // inside an expanded Select, sits in front and answers its own clicks
    // first; this only catches whatever reaches bare row background.
    MouseArea {
        anchors.fill: parent

        z: -1
        enabled: root.clickable
        cursorShape: root.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: root.clicked()
    }
}
