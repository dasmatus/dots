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
// wrong, and measurably so. QML does not diff a JS array assigned to `model`:
// QQuickItemView::setModel compares the converted list against the old one and
// either early-returns on an equal list or clears the view and repositions to
// the top on an unequal one. There is no middle path where it updates in
// place.
//
// The trigger is inequality, NOT length. Editing one row's text at a constant
// length resets the view exactly as an append does. That is the case that
// matters, because it is what streaming IS: appendText replaces the open row
// with a grown-text object, applyEvents slices a fresh array, and the result
// is an unequal list on every 16ms flush. So a reader who scrolled up to
// reread something was thrown back to the top continuously for the length of
// an answer. `positionViewAtEnd` hid it from a pinned reader, which is exactly
// the reader who did not need the help.
//
// An integer model fixes the streaming case, since the count does not change
// while text grows, but still resets on every append. A ListModel is the only
// shape that survives both: appending to one is an insertion, and editing a
// row touches it not at all. So the model is a ListModel carrying one
// throwaway integer per row, synced to `rows.length`, and the delegate reads
// the real row out of the array by index. Nothing rich ever enters the
// ListModel, which also sidesteps its habit of converting a nested JS object
// into nested ListModels, and these rows carry nulls and nested result, diff
// and permission records that would not survive that.
//
// tests/qml/tst_ask_layout.qml measures all six cases. It also keeps the
// identical-array early-return as its own test, because an earlier version of
// this comment was written from exactly that measurement: comparing an array
// against a copy of itself always comes back clean, whatever the semantics.
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
