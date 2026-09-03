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
// by the next token. `follow` records that, and only then does the view chase
// the tail.
//
// WHY THE MODEL IS A ListModel OF NOTHING. The obvious `model: root.rows` is
// wrong, and measurably so. QML does not diff a JS array assigned to `model`.
// Measured on Qt 6.11 (tests/qml/tst_ask_layout.qml pins all of it): assigning
// a new array of the SAME length keeps contentY and rebuilds no delegate, but
// assigning one of a DIFFERENT length is a model reset, which tears down every
// visible delegate and snaps contentY to 0. The fold appends a row on every
// new block, tool call, code block and status line, so a reader who scrolled
// up to reread something got thrown back to the top of the conversation
// several times a turn. `positionViewAtEnd` hid it from a pinned reader, which
// is exactly the reader who did not need the help.
//
// An integer model has the same fault, measured the same way. A ListModel does
// not: appending to one is an insertion, so contentY holds and nothing is
// rebuilt. So the model is a ListModel carrying one throwaway integer per row,
// synced to `rows.length`, and the delegate reads the real row out of the
// array by index. Nothing rich ever enters the ListModel, which also sidesteps
// its habit of converting a nested JS object into nested ListModels.
//
// Editing a row still costs nothing: `rows` changes identity, every visible
// delegate's `root.rows[index]` binding re-evaluates, and the offscreen ones
// are not built to care. That is O(visible), not O(conversation), per frame.
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

    // Brings the backing model's count to the row count, by insertion and
    // removal rather than by replacement. The element is a plain integer and
    // nothing reads it; the count is the whole point.
    function sync(): void {
        while (backing.count > root.rows.length)
            backing.remove(backing.count - 1, 1);

        while (backing.count < root.rows.length)
            backing.append({
                n: backing.count
            });
    }

    model: ListModel {
        id: backing
    }

    spacing: Theme.askRowSpacing

    clip: true
    reuseItems: true
    boundsBehavior: Flickable.StopAtBounds

    onRowsChanged: root.sync()
    Component.onCompleted: root.sync()

    delegate: Message {
        required property int index

        width: ListView.view.width

        // Guarded because the model is synced from a handler, so a delegate
        // can evaluate this once while the array has already shrunk and the
        // backing model has not caught up. Message renders a null row as
        // nothing, which is the right answer for a row that is on its way out.
        row: root.rows[index] ?? null
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
