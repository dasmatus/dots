// The two layout rules the ask pane's cards and its thread depend on, pinned
// against real QtQuick rather than against a comment. Both exist because a
// defect got through 780 passing tests.
//
// The DIFF CARD is tested on the shipped file itself. DiffView.qml imports
// QtQuick, QtQuick.Layouts and Theme and nothing else, which is exactly the
// profile fixtures/theme-stub/ serves, so it loads here through a symlink the
// same way Chrome.qml and Field.qml already do. An earlier version of this
// header claimed it could not load. That was wrong, and it cost the component
// a real render test it could have had from the start.
//
// The THREAD is not, and here the limit is real: its delegate is Message,
// which reaches the AskBus singleton and its Socket. CodeBlock is out for the
// same kind of reason, importing Quickshell for the clipboard. So the model
// rules below are proved on a plain QtQuick replica, and tst_ask_wiring.qml
// pins Thread.qml to the shape the replica proves. The replica shows the rule
// is real; the scan shows the file still follows it. Neither half is worth
// much alone, which is the honest description of that coverage.
//
// A rendering test, so `when: windowShown` and the items go through
// createTemporaryObject. Offscreen QPA still lays out and still reports real
// geometry, which is the whole reason these can exist at all.
import QtQuick
import QtQuick.Layouts
import QtTest
import "fixtures/theme-stub/ask"

TestCase {
    name: "AskLayout"
    when: windowShown

    width: 400
    height: 300

    // The shape DiffView shipped with. A ColumnLayout holding a header and a
    // fill-height Flickable, measured through the column the way the card did.
    Component {
        id: flickableCard

        ColumnLayout {
            spacing: 6

            Text {
                Layout.fillWidth: true

                text: "path/to/file.rs"
            }

            Flickable {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.minimumHeight: 0

                contentWidth: flickBody.implicitWidth
                contentHeight: flickBody.implicitHeight

                Text {
                    id: flickBody

                    text: "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight"
                }
            }
        }
    }

    // The body on its own, so a test can say how tall the diff actually wants
    // to be without reaching into a Flickable's contentItem.
    Component {
        id: bareBody

        Text {
            text: "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight"
        }
    }

    // A FLICKABLE HAS NO IMPLICIT HEIGHT. This is the whole of the DiffView
    // defect. The card summed column.implicitHeight, the column's only
    // fill-height child was a Flickable, the Flickable contributed 0, and the
    // card measured its header alone. The path and the +N/-N counts drew and
    // the diff body was clipped to nothing.
    function test_a_fill_height_flickable_contributes_no_implicit_height() {
        const card = createTemporaryObject(flickableCard, this);
        const body = createTemporaryObject(bareBody, this);
        waitForRendering(card);

        const header = card.children[0];
        const flick = card.children[1];

        compare(flick.implicitHeight, 0, "a Flickable reports no implicit height of its own");
        verify(body.implicitHeight > 0, "the body it holds does want real height");

        // What the shipped card used to compute, and what it has to compute.
        const throughColumn = card.implicitHeight;
        const throughBody = header.implicitHeight + body.implicitHeight + card.spacing;

        verify(throughColumn < throughBody, `measuring through the column (${throughColumn}) cannot cover the body (${throughBody}), which is why a card must sum the body's own implicitHeight`);
        verify(throughColumn <= header.implicitHeight + card.spacing, "measuring through the column yields the header and nothing else");
    }

    // The corrected arithmetic, which is what both CodeBlock and DiffView use:
    // sum the body's own implicitHeight rather than trusting the layout to
    // have one, then cap it.
    function test_summing_the_body_covers_it_and_still_caps() {
        const card = createTemporaryObject(flickableCard, this);
        const body = createTemporaryObject(bareBody, this);
        waitForRendering(card);

        const header = card.children[0];
        const gutter = 8;
        const cap = 340;

        const sized = Math.min(header.implicitHeight + body.implicitHeight + card.spacing + gutter * 2, cap);

        verify(sized > header.implicitHeight + gutter * 2, "the card must be taller than its own header once the body is counted");
        verify(sized - header.implicitHeight - card.spacing - gutter * 2 >= body.implicitHeight - 1, "and it must leave the body its full height when under the cap");

        const tall = createTemporaryObject(bareBody, this);
        tall.text = "line\n".repeat(400);
        waitForRendering(tall);

        compare(Math.min(header.implicitHeight + tall.implicitHeight + card.spacing + gutter * 2, cap), cap, "a long diff still has to stop at the cap rather than growing without bound");
    }

    // THE REAL DiffView, not a replica.
    //
    // It imports QtQuick, QtQuick.Layouts and Theme and nothing else, which is
    // exactly the profile fixtures/theme-stub serves, so it loads here through
    // a symlink to the shipped file the same way Chrome and Field already do.
    // The replicas above prove the QtQuick rule in the abstract; these two
    // prove the shipped component obeys it.
    Component {
        id: realDiff

        DiffView {
            width: 400

            path: "/home/matus/src/parser.rs"
            newText: "fn main() {}\nlet x = 1;\nlet y = 2;\nlet z = 3;\nreturn x + y + z;"
            added: 4
            removed: 1
        }
    }

    function test_the_real_diff_card_gives_its_body_real_height() {
        const diff = createTemporaryObject(realDiff, this);
        waitForRendering(diff);

        const column = diff.children[0];
        const header = column.children[0];
        const flick = column.children[1];

        verify(diff.implicitHeight > 0, "the card has to have a height at all");

        // The defect this pins: the card measured its header alone and the
        // Flickable holding the diff got zero, so the body was clipped away
        // while the path and the counts still drew.
        verify(flick.contentHeight > 0, "the diff body has to want real height for this test to mean anything");
        verify(flick.height >= flick.contentHeight, `the diff body must not be clipped: Flickable height ${flick.height} against contentHeight ${flick.contentHeight}`);
        verify(diff.implicitHeight > header.implicitHeight * 2, `the card (${diff.implicitHeight}) must be taller than its own header (${header.implicitHeight}), or only the path and counts are visible`);
    }

    function test_the_real_diff_card_still_caps_a_long_diff() {
        const diff = createTemporaryObject(realDiff, this);
        diff.newText = "a line of diff\n".repeat(400);
        waitForRendering(diff);

        compare(diff.implicitHeight, 340, "a long diff has to stop at Theme.askCodeMaxHeight rather than growing without bound");
    }

    // A ListView carrying rows. Three model shapes, so the test can say which
    // one survives an append rather than asserting the one that was picked.
    Component {
        id: arrayModelView

        ListView {
            id: arrayView

            property var rows: []
            property int torn: 0

            width: 200
            height: 100

            model: arrayView.rows

            delegate: Rectangle {
                width: 200
                height: 20

                Component.onDestruction: arrayView.torn++
            }
        }
    }

    Component {
        id: listModelView

        ListView {
            id: backedView

            property var rows: []
            property int torn: 0

            width: 200
            height: 100

            function sync() {
                while (backing.count > backedView.rows.length)
                    backing.remove(backing.count - 1, 1);

                while (backing.count < backedView.rows.length)
                    backing.append({
                        n: backing.count
                    });
            }

            model: ListModel {
                id: backing
            }

            onRowsChanged: backedView.sync()

            delegate: Rectangle {
                required property int index

                readonly property string label: backedView.rows[index] ? backedView.rows[index].t : "(gone)"

                width: 200
                height: 20

                Component.onDestruction: backedView.torn++
            }
        }
    }

    function makeRows(n) {
        const out = [];
        for (let i = 0; i < n; i++)
            out.push({
                t: `row ${i}`
            });
        return out;
    }

    // The same list with one row's text replaced. This is what ask.js's
    // appendText produces on every flush: a freshly sliced array of the same
    // length, holding one grown-text row and otherwise the same content.
    function editedRows(n, at, text) {
        const out = makeRows(n);
        out[at] = {
            t: text
        };
        return out;
    }

    // WHY THE THREAD DOES NOT USE `model: rows`.
    //
    // The trigger is QQuickItemView::setModel's equality check on the
    // converted list, NOT the length. An equal list early-returns; an unequal
    // one clears the view and repositions to the top. Editing one row's text
    // at a constant length makes the list unequal, so it resets exactly as an
    // append does.
    //
    // That is the case that matters, because it is what streaming does. Every
    // 16ms flush that grows the open text row hands over an unequal list, so a
    // reader who had scrolled up to reread something was thrown back to the
    // top continuously for the length of an answer.
    function test_an_array_model_resets_the_view_on_an_edited_row() {
        const view = createTemporaryObject(arrayModelView, this);
        view.rows = makeRows(50);
        waitForRendering(view);

        view.contentY = 400;
        waitForRendering(view);
        compare(view.contentY, 400, "the probe has to start scrolled up or it proves nothing");

        view.torn = 0;
        view.rows = editedRows(50, 23, "CHANGED");
        waitForRendering(view);

        compare(view.contentY, 0, "editing one row at the same length still resets a JS array model to the top");
        verify(view.torn > 0, "and tears down the delegates that were on screen");
    }

    function test_an_array_model_resets_the_view_when_it_grows() {
        const view = createTemporaryObject(arrayModelView, this);
        view.rows = makeRows(50);
        waitForRendering(view);

        view.contentY = 400;
        waitForRendering(view);

        view.torn = 0;
        view.rows = makeRows(51);
        waitForRendering(view);

        compare(view.contentY, 0, "growing a JS array model resets the view to the top");
        verify(view.torn > 0, "and tears down the delegates that were on screen");
    }

    // The early-return, recorded so nobody measures it by accident again.
    //
    // An array whose content is identical compares equal and is dropped on the
    // floor. This test asserts almost nothing about the view, and that is the
    // point of keeping it: an earlier version of this file used exactly this
    // shape to conclude that same-length reassignment was safe, which is
    // wrong. Two identical arrays always compare equal, so that measurement
    // could only ever come back clean whatever the model semantics were.
    function test_an_identical_array_is_an_early_return_not_a_data_change() {
        const view = createTemporaryObject(arrayModelView, this);
        view.rows = makeRows(50);
        waitForRendering(view);

        view.contentY = 400;
        waitForRendering(view);

        view.torn = 0;
        view.rows = makeRows(50);
        waitForRendering(view);

        compare(view.contentY, 400, "an equal list early-returns, which proves equality and nothing about editing");
        compare(view.torn, 0, "so nothing is rebuilt, for a reason that does not generalise");
    }

    // What Thread.qml uses instead: a ListModel carrying one throwaway integer
    // per row, synced by insertion and removal, with the delegate reading the
    // real row out of the array by index. Appending to a ListModel is an
    // insertion, so the viewport holds.
    function test_a_listmodel_of_indices_survives_an_append() {
        const view = createTemporaryObject(listModelView, this);
        view.rows = makeRows(50);
        waitForRendering(view);

        view.contentY = 400;
        waitForRendering(view);

        view.torn = 0;
        view.rows = makeRows(51);
        waitForRendering(view);

        compare(view.contentY, 400, "appending through a ListModel must leave a scrolled-up reader where they were");
        compare(view.torn, 0, "and must rebuild nothing");
    }

    // The case the array model gets wrong and this one has to get right:
    // editing a row's text at a constant length, which is what streaming does
    // every frame. The ListModel does not change at all, so the update rides
    // entirely on the delegate's own binding into the array re-evaluating.
    function test_a_listmodel_holds_position_through_an_edited_row() {
        const view = createTemporaryObject(listModelView, this);
        view.rows = makeRows(50);
        waitForRendering(view);

        view.contentY = 400;
        waitForRendering(view);

        view.torn = 0;
        view.rows = editedRows(50, 23, "CHANGED");
        waitForRendering(view);

        const item = view.itemAtIndex(23);

        verify(item !== null, "row 23 has to be realized at this scroll position for the check to mean anything");
        compare(item.label, "CHANGED", "an edited row must reach the delegate even though the model itself did not change");
        compare(view.contentY, 400, "and a streaming edit must leave a scrolled-up reader where they were");
        compare(view.torn, 0, "rebuilding nothing");
    }

    // The same, with a row appended alongside the edit, which is the mixed
    // batch a real flush produces when a turn opens a new block.
    function test_a_listmodel_still_sees_an_edited_row_while_growing() {
        const view = createTemporaryObject(listModelView, this);
        view.rows = makeRows(50);
        waitForRendering(view);

        view.contentY = 400;
        waitForRendering(view);

        const next = makeRows(51);
        next[23] = {
            t: "CHANGED"
        };
        view.rows = next;
        waitForRendering(view);

        const item = view.itemAtIndex(23);

        verify(item !== null, "row 23 has to be realized at this scroll position for the check to mean anything");
        compare(item.label, "CHANGED", "an edit riding along with an append still has to reach the delegate");
        compare(view.contentY, 400, "and the viewport still holds");
    }
}
