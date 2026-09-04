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
import "../common"
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
        case "artifact":
            return artifactRow;
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

    // The prompt the user sent, and whatever rode with it. Echoed by the
    // client rather than folded from the daemon's `user_message`; ask.js's
    // pushUserRow says what that still costs after a shell restart.
    Component {
        id: userRow

        Rectangle {
            implicitHeight: promptBody.implicitHeight + Theme.askGutter * 2

            radius: Theme.askRadius
            color: Qt.alpha(Theme.accent, 0.14)
            border.width: 1
            border.color: Theme.accent

            ColumnLayout {
                id: promptBody

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Theme.askGutter

                spacing: 6

                Text {
                    Layout.fillWidth: true

                    visible: root.row.text !== ""
                    text: root.row.text
                    textFormat: Text.PlainText
                    color: Theme.fg

                    font.family: Theme.fontUi
                    font.pointSize: 10

                    wrapMode: Text.Wrap
                }

                // What was attached, by name. Not a thumbnail: the path this
                // row holds is the composer's scratch copy, which the tmpfs
                // clears at logout, so an Image bound to it would draw a
                // broken frame for the rest of the session. The daemon's own
                // copy is the durable one and this side does not know its
                // name.
                Flow {
                    Layout.fillWidth: true

                    visible: (root.row.attachments ?? []).length > 0
                    spacing: 6

                    Repeater {
                        model: root.row.attachments ?? []

                        delegate: Pill {
                            id: sent

                            required property var modelData

                            color: Qt.alpha(Theme.accent, 0.2)

                            Text {
                                text: sent.modelData.name
                                textFormat: Text.PlainText
                                color: Theme.fgDark

                                font.family: Theme.fontMono
                                font.pointSize: 9
                            }
                        }
                    }
                }
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

    // A model-written HTML page, as a card that opens it in its own window.
    //
    // A card and not a preview, because there is nothing here that could draw
    // one: Quickshell cannot host QtWebEngine, which is the reason artifacts
    // leave the pane at all. The `code_block` beside this row carries the same
    // page as source, so a reader who wants to know what the button will open
    // can read it without opening it.
    //
    // The card is greyed when the daemon reported no artifact_base, which
    // means the page is on disk and nothing is serving it. Saying so is better
    // than a button that does nothing.
    Component {
        id: artifactRow

        Rectangle {
            id: card

            readonly property string url: AskMath.artifactUrl(AskBus.state, root.conversation, root.row.artifact)
            readonly property bool openable: card.url !== ""

            implicitHeight: cardBody.implicitHeight + Theme.askGutter * 2

            radius: Theme.askRadius
            color: Theme.bgDark
            border.width: 1
            border.color: card.openable ? Theme.accent : Theme.border

            RowLayout {
                id: cardBody

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Theme.askGutter

                spacing: 8

                ColumnLayout {
                    Layout.fillWidth: true

                    spacing: 2

                    Text {
                        Layout.fillWidth: true

                        text: root.row.title ?? "Untitled page"
                        textFormat: Text.PlainText
                        color: Theme.fg
                        elide: Text.ElideRight

                        font.family: Theme.fontUi
                        font.pointSize: 10
                        font.bold: true
                    }

                    // The revision is shown from the second one on. "revision
                    // 1" on every first page would be noise; "revision 3" is
                    // the thing worth noticing, because it says the window
                    // that is already open has been reloaded twice.
                    Text {
                        Layout.fillWidth: true

                        text: {
                            if (!card.openable)
                                return "written to disk; no artifact server is running";

                            const size = `${Math.max(1, Math.round(root.row.bytes / 1024))} KiB`;
                            return root.row.revision > 1 ? `HTML · ${size} · revision ${root.row.revision}` : `HTML · ${size}`;
                        }
                        textFormat: Text.PlainText
                        color: Theme.muted

                        font.family: Theme.fontMono
                        font.pointSize: 8
                    }
                }

                Pill {
                    interactive: card.openable
                    color: card.openable ? Theme.accent : Theme.bgDarker

                    onClicked: AskBus.openArtifact(root.conversation, root.row.artifact)

                    Text {
                        text: "Open"
                        color: card.openable ? Theme.bg : Theme.muted

                        font.family: Theme.fontUi
                        font.pointSize: 9
                        font.bold: true
                    }
                }
            }
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
                textFormat: Text.PlainText
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
                textFormat: Text.PlainText
                color: Theme.red

                font.family: Theme.fontUi
                font.pointSize: 9

                wrapMode: Text.Wrap
            }
        }
    }
}
