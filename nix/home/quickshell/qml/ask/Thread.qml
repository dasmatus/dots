// The conversation itself: every row the daemon has sent for one thread, in
// arrival order.
//
// A ListView rather than a Column in a Flickable, so a long thread only ever
// builds the delegates on screen. That matters more here than in the launcher:
// a launcher list is capped at fifty rows and a conversation is not capped at
// all.
//
// STICKY BOTTOM. A streaming answer grows the content under the viewport, and
// the reader wants to stay at the newest line without dragging. But only while
// they are already there: scrolling up to reread something must not be undone
// by the next token. `pinned` records whether the view was at the bottom before
// the content grew, and only then does it follow.
pragma ComponentBehavior: Bound

import QtQuick
import ".."

ListView {
    id: root

    required property string conversation
    required property var rows

    // Whether new content should pull the viewport with it.
    //
    // Deliberately NOT a binding over contentY: by the time a growth handler
    // runs, contentHeight has already changed, so a binding would say "not at
    // the bottom" precisely because the content just grew, and the pin would
    // release itself on the first token. This is set from movement instead, so
    // it only ever changes when the reader moves the view.
    property bool follow: true

    model: root.rows
    spacing: Theme.askRowSpacing

    clip: true
    reuseItems: true
    boundsBehavior: Flickable.StopAtBounds

    delegate: Message {
        required property var modelData

        width: ListView.view.width

        row: modelData
        conversation: root.conversation
    }

    // Scrolling up releases the pin; scrolling back to the bottom takes it
    // again. Reading `atYEnd` here rather than in the growth handler is what
    // keeps the two apart: this fires when the reader moved, that one fires
    // when the answer did.
    onMovementEnded: root.follow = root.atYEnd

    // Follows the tail only while the pin is held. positionViewAtEnd rather
    // than an animated scroll: a smooth scroll restarted by every 16ms flush
    // never arrives, and the tail would trail the text by a fixed gap for as
    // long as the answer kept coming.
    onContentHeightChanged: {
        if (root.follow)
            root.positionViewAtEnd();
    }

    // A thread swap is not a scroll. Whatever was on screen belonged to the
    // other conversation, so this one starts at its own end, pinned again.
    onConversationChanged: {
        root.follow = true;
        root.positionViewAtEnd();
    }
}
