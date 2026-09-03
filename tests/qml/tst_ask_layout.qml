// The two layout rules the ask pane's cards and its thread depend on, pinned
// against real QtQuick rather than against a comment.
//
// Both exist because a defect got through 780 passing tests. Nothing in this
// suite can instantiate DiffView or Thread themselves: both reach `Theme`,
// which is a Quickshell singleton, and Thread's delegate reaches AskBus, which
// owns a Socket. tests/README.md rules all of that out. So each rule is proved
// here on a plain QtQuick replica of the shape, and the shipped file is pinned
// to that shape by a source scan in tst_ask_wiring.qml. The replica proves the
// rule is real; the scan proves the file still follows it.
//
// A rendering test, so `when: windowShown` and the items go through
// createTemporaryObject. Offscreen QPA still lays out and still reports real
// geometry, which is the whole reason these can exist at all.
import QtQuick
import QtQuick.Layouts
import QtTest

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

    // WHY THE THREAD DOES NOT USE `model: rows`. Assigning a JS array of a
    // DIFFERENT length is a model reset: QML tears down every visible delegate
    // and snaps contentY to 0. The fold appends a row on every new block, tool
    // call, code block and status line, so a reader who had scrolled up to
    // reread something got thrown back to the top several times a turn.
    function test_an_array_model_resets_the_view_when_it_grows() {
        const view = createTemporaryObject(arrayModelView, this);
        view.rows = makeRows(50);
        waitForRendering(view);

        view.contentY = 400;
        waitForRendering(view);
        compare(view.contentY, 400, "the probe has to start scrolled up or it proves nothing");

        view.torn = 0;
        view.rows = makeRows(51);
        waitForRendering(view);

        compare(view.contentY, 0, "growing a JS array model resets the view to the top");
        verify(view.torn > 0, "and tears down the delegates that were on screen");
    }

    // The same array model is fine when the length does not change, which is
    // why plain streaming into one open text row never showed this. Measured
    // rather than assumed, because it is the reason the defect stayed hidden.
    function test_an_array_model_is_stable_when_the_length_holds() {
        const view = createTemporaryObject(arrayModelView, this);
        view.rows = makeRows(50);
        waitForRendering(view);

        view.contentY = 400;
        waitForRendering(view);

        view.torn = 0;
        view.rows = makeRows(50);
        waitForRendering(view);

        compare(view.contentY, 400, "a same-length reassignment is a data change, not a reset");
        compare(view.torn, 0, "so nothing is rebuilt");
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

    // The other half: editing a row still has to reach the delegate. The
    // ListModel never changes, so the update rides entirely on the delegate's
    // own binding into the array re-evaluating.
    function test_a_listmodel_still_sees_an_edited_row() {
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
        compare(item.label, "CHANGED", "an edited row must reach the delegate even though the model itself did not change");
        compare(view.contentY, 400, "and editing must not move the viewport either");
    }
}
