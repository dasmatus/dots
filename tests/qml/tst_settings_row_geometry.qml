// Pins SettingsRow.qml's contract: the dependent-row dimming/disabling the
// task brief calls out by name, the indent that marks a row as dependent in
// the first place, and the height formula that lets a tall control (an
// expanded Select.qml) grow the row instead of clipping against it.
//
// SettingsRow.qml only reaches QtQuick, QtQuick.Layouts and Theme — no
// Quickshell type — which is what lets qmltestrunner instantiate it
// directly, the same reasoning tst_chrome_geometry.qml's own header gives
// for Chrome.qml.
import QtQuick
import QtQuick.Layouts
import QtTest
import "fixtures/theme-stub/settings"

TestCase {
    id: testCase
    name: "SettingsRowGeometry"

    Component {
        id: plainRow
        SettingsRow {
            width: 400
            title: "Git name"
            description: "Used for commit authorship"
        }
    }

    Component {
        id: dependentRow
        SettingsRow {
            width: 400
            title: "T"
            description: "D"
            dependent: true
        }
    }

    Component {
        id: independentRow
        SettingsRow {
            width: 400
            title: "T"
            description: "D"
            dependent: false
        }
    }

    Component {
        id: offRow
        SettingsRow {
            width: 400
            title: "T"
            description: "D"
            dependsOn: false
        }
    }

    Component {
        id: onRow
        SettingsRow {
            width: 400
            title: "T"
            description: "D"
            dependsOn: true
        }
    }

    Component {
        id: shortControlRow
        SettingsRow {
            width: 400
            title: "T"
        }
    }

    Component {
        id: tallControlRow
        SettingsRow {
            width: 400
            title: "T"

            Item {
                width: 10
                height: 300
            }
        }
    }

    // The title/description Text pair two levels inside `layout`: the
    // left-hand ColumnLayout is `layout`'s first child, and its own two
    // children are the title and the description in declaration order.
    function textPair(row) {
        const column = row.children[0].children[0];
        return [column.children[0], column.children[1]];
    }

    function test_title_and_description_render_as_given() {
        const row = createTemporaryObject(plainRow, testCase);
        verify(row !== null);

        const pair = textPair(row);
        compare(pair[0].text, "Git name");
        compare(pair[1].text, "Used for commit authorship");
    }

    function test_dimmed_when_dependency_is_off() {
        const off = createTemporaryObject(offRow, testCase);
        const on = createTemporaryObject(onRow, testCase);
        verify(off !== null);
        verify(on !== null);

        compare(off.opacity, 0.45, "a row whose dependsOn is false must dim to ~45%, per the task brief");
        compare(on.opacity, 1, "a row whose dependsOn is true must stay fully opaque");
    }

    // dependsOn is assigned straight onto the row's own built-in `enabled`,
    // which is what makes a dependent row's controls disable for free —
    // QtQuick already refuses input to a disabled item's children.
    function test_dependency_off_disables_the_row() {
        const off = createTemporaryObject(offRow, testCase);
        const on = createTemporaryObject(onRow, testCase);
        verify(off !== null);
        verify(on !== null);

        compare(off.enabled, false, "dependsOn: false must disable the row so its controls stop taking input");
        compare(on.enabled, true);
    }

    // `layout`'s anchors.leftMargin is Theme.settingsRowPadding, plus 24 more
    // when `dependent` is true — so `layout.x` (root.children[0].x, since
    // layout is root's sole child) must differ by exactly that 24px between
    // an otherwise-identical dependent and independent row.
    function test_dependent_row_indents_by_24px() {
        const dependent = createTemporaryObject(dependentRow, testCase);
        const independent = createTemporaryObject(independentRow, testCase);
        verify(dependent !== null);
        verify(independent !== null);

        compare(dependent.children[0].x - independent.children[0].x, 24, "a dependent row must sit exactly 24px further right than an otherwise identical non-dependent row");
    }

    // The regression this exists for: a control that grows after the row
    // has already been laid out (Select.qml's option list opening) must
    // grow the row's own implicitHeight along with it, or the option list
    // clips against — or paints under — the row that follows.
    function test_row_grows_to_fit_a_tall_control() {
        const short = createTemporaryObject(shortControlRow, testCase);
        const tall = createTemporaryObject(tallControlRow, testCase);
        verify(short !== null);
        verify(tall !== null);

        compare(short.implicitHeight, 56, "a row with no oversized control must sit at the palette's own settingsRowHeight");
        verify(tall.implicitHeight >= 300, "a 300px-tall control must be counted in the row's own implicitHeight rather than clipped");
    }
}
