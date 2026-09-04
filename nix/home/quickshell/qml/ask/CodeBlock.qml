// One fenced code block, already highlighted.
//
// This file draws; it does not decide. The daemon's render.rs runs
// pulldown-cmark and syntect and sends the result as `html`, a small rich-text
// subset a QML Text element understands, so there is no markdown parser and no
// highlighter in QML. Quickshell cannot host QtWebEngine either, which is why
// the subset is small on purpose rather than a page.
//
// `source` is the plain text behind that rich text and is what the copy button
// puts on the clipboard. Copying the rich text would paste markup.
//
// `html` is Option<String> on the wire, null until the daemon has a renderer
// for the language. A null one falls back to the monospace plain text, which
// is the same content without the colour rather than an empty box.
import QtQuick
import QtQuick.Layouts
import Quickshell
import ".."
import "../common"

Rectangle {
    id: root

    property string language: ""
    property string source: ""
    property string html: ""

    readonly property bool highlighted: root.html !== ""

    implicitHeight: Math.min(body.implicitHeight + header.height + Theme.askGutter * 3, Theme.askCodeMaxHeight)

    radius: Theme.askRadius
    color: Theme.bgDarker
    border.width: 1
    border.color: Theme.border

    RowLayout {
        id: header

        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: Theme.askGutter

        height: copy.implicitHeight
        spacing: Theme.askGutter

        Text {
            Layout.fillWidth: true

            text: root.language === "" ? "code" : root.language
            textFormat: Text.PlainText
            color: Theme.muted

            font.family: Theme.fontMono
            font.pointSize: 9

            elide: Text.ElideRight
        }

        Pill {
            id: copy

            interactive: true
            color: copied.running ? Theme.green : Theme.bgDark

            // Quickshell holds a live Wayland connection, so this is a
            // property assignment rather than a fork of wl-copy.
            onClicked: {
                Quickshell.clipboardText = root.source;
                copied.restart();
            }

            Text {
                text: copied.running ? "copied" : "copy"
                color: copied.running ? Theme.bg : Theme.fgDark

                font.family: Theme.fontUi
                font.pointSize: 9
                font.bold: true
            }
        }
    }

    // Confirms the copy for a moment and then puts the label back, so the
    // button says what happened without a toast.
    Timer {
        id: copied

        interval: 1200
        repeat: false
    }

    Flickable {
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: Theme.askGutter

        // Code scrolls sideways rather than wrapping. A wrapped line hides
        // which indentation level it belongs to, and indentation is most of
        // what makes a diff or a function readable at a glance.
        contentWidth: body.implicitWidth
        contentHeight: body.implicitHeight
        clip: true

        Text {
            id: body

            // RichText for the highlighted form and PlainText for the
            // fallback, never StyledText: the fallback is raw source, and
            // StyledText would try to read an angle bracket in it as a tag.
            text: root.highlighted ? root.html : root.source
            textFormat: root.highlighted ? Text.RichText : Text.PlainText
            color: Theme.fg

            font.family: Theme.fontMono
            font.pointSize: 10

            wrapMode: Text.NoWrap
        }
    }
}
