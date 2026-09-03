// One row in a thread, whichever of the eight kinds it is.
//
// The kinds come from ask.js's fold: user, text, thinking, code, tool, plan,
// status and error. Every one of them is a row in the same list rather than a
// separate lane, because the order they arrived in is the order they happened
// in, and a tool call that ran between two paragraphs belongs between them.
//
// One Loader rather than eight children switched on `visible`. A delegate that
// built every kind and hid seven of them would carry seven idle bindings per
// visible row, and a long answer is mostly text rows that need none of the
// rest.
//
// THINKING IS A PROGRESS INDICATOR, NOT A TRANSCRIPT. Task 0 recorded 12
// thinking_delta events from the claude harness and every one carried an empty
// string, zero characters in total. Only estimated_tokens carries signal. A
// text view here would be permanently blank, so this renders a token count and
// a pulse instead. Raw providers do send real reasoning text, so the switch is
// `chars > 0`, which is what actually arrived, rather than the backend's name.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import ".."
import "../services"
import "../services/ask.js" as AskMath

Loader {
    id: root

    required property var row
    required property string conversation

    readonly property string kind: root.row ? root.row.kind : ""

    sourceComponent: {
        switch (root.kind) {
        case "user":
            return userRow;
        case "text":
            return textRow;
        case "thinking":
            return thinkingRow;
        case "code":
            return codeRow;
        case "tool":
            return toolRow;
        case "plan":
            return planRow;
        case "status":
            return statusRow;
        case "error":
            return errorRow;
        default:
            return null;
        }
    }

    // The prompt the user sent. Echoed by the client, because no daemon event
    // carries a user message back; ask.js's pushUserRow says what that costs
    // after a shell restart.
    Component {
        id: userRow

        Rectangle {
            implicitHeight: prompt.implicitHeight + Theme.askGutter * 2

            radius: Theme.askRadius
            color: Qt.alpha(Theme.accent, 0.14)
            border.width: 1
            border.color: Theme.accent

            Text {
                id: prompt

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Theme.askGutter

                text: root.row.text
                color: Theme.fg

                font.family: Theme.fontUi
                font.pointSize: 10

                wrapMode: Text.Wrap
            }
        }
    }

    // Assistant prose. PlainText on purpose: the daemon sends rich text only
    // for a code block and a diff, so anything arriving here is literal and an
    // angle bracket in it is a character, not a tag.
    Component {
        id: textRow

        Text {
            text: root.row.text
            textFormat: Text.PlainText
            color: Theme.fg

            font.family: Theme.fontUi
            font.pointSize: 10

            wrapMode: Text.Wrap
        }
    }

    Component {
        id: thinkingRow

        ColumnLayout {
            spacing: 4

            RowLayout {
                Layout.fillWidth: true

                spacing: 8

                Rectangle {
                    Layout.preferredWidth: 8
                    Layout.preferredHeight: 8

                    radius: 4
                    color: Theme.magenta

                    // Pulses only while the turn is still running, so a
                    // finished thread sits still rather than blinking at every
                    // block it ever produced.
                    SequentialAnimation on opacity {
                        running: AskBus.liveTurnOf(root.conversation) !== null
                        loops: Animation.Infinite

                        NumberAnimation {
                            from: 0.25
                            to: 1
                            duration: 700
                        }
                        NumberAnimation {
                            from: 1
                            to: 0.25
                            duration: 700
                        }
                    }
                }

                Text {
                    Layout.fillWidth: true

                    text: root.row.tokens === null ? "thinking" : `thinking, about ${root.row.tokens} tokens`
                    color: Theme.magenta

                    font.family: Theme.fontUi
                    font.pointSize: 9
                    font.italic: true

                    elide: Text.ElideRight
                }
            }

            // The one case where reasoning text really arrived. Gated on the
            // character count rather than on a backend name, since the
            // Anthropic API and a few ollama models do send it and the harness
            // never does.
            Text {
                Layout.fillWidth: true

                visible: root.row.chars > 0
                text: root.row.text
                textFormat: Text.PlainText
                color: Theme.muted

                font.family: Theme.fontUi
                font.pointSize: 9
                font.italic: true

                wrapMode: Text.Wrap
            }
        }
    }

    Component {
        id: codeRow

        CodeBlock {
            language: root.row.language ?? ""
            source: root.row.source
            html: root.row.html ?? ""
        }
    }

    Component {
        id: toolRow

        ToolCall {
            row: root.row

            onDecided: (request, decision, scope) => AskBus.decide(root.conversation, request, decision, scope)
        }
    }

    // A plan card. Raw providers never send one: plan comes from the harness
    // ExitPlanMode tool, and provider mode has no file tools at all, so there
    // is nothing there to plan against.
    Component {
        id: planRow

        Rectangle {
            implicitHeight: planBody.implicitHeight + planTitle.implicitHeight + Theme.askGutter * 3

            radius: Theme.askRadius
            color: Theme.bgDark
            border.width: 1
            border.color: Theme.cyan

            Text {
                id: planTitle

                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: Theme.askGutter

                text: root.row.title ?? "Plan"
                color: Theme.cyan

                font.family: Theme.fontUi
                font.pointSize: 10
                font.bold: true

                elide: Text.ElideRight
            }

            Text {
                id: planBody

                anchors.top: planTitle.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: Theme.askGutter

                text: root.row.markdown
                textFormat: Text.PlainText
                color: Theme.fgDark

                font.family: Theme.fontUi
                font.pointSize: 9

                wrapMode: Text.Wrap
            }
        }
    }

    // How a turn ended, and only when it ended in a way worth saying so. An
    // interrupt lands here in muted grey, never in the error style: the user
    // asked for it, and it raised no error event at all.
    Component {
        id: statusRow

        Text {
            text: root.row.durationMs === null ? AskMath.stopLabel(root.row.stop) : `${AskMath.stopLabel(root.row.stop)} after ${Math.round(root.row.durationMs / 100) / 10}s`
            color: AskMath.isFailure(root.row.stop) ? Theme.red : Theme.muted

            font.family: Theme.fontUi
            font.pointSize: 9

            elide: Text.ElideRight
        }
    }

    Component {
        id: errorRow

        Rectangle {
            implicitHeight: failure.implicitHeight + Theme.askGutter * 2

            radius: Theme.askRadius
            color: Qt.alpha(Theme.red, 0.12)
            border.width: 1
            border.color: Theme.red

            Text {
                id: failure

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Theme.askGutter

                text: `${root.row.errorKind}: ${root.row.message}`
                color: Theme.red

                font.family: Theme.fontUi
                font.pointSize: 9

                wrapMode: Text.Wrap
            }
        }
    }
}
