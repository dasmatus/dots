// Executes the claim every j/k comment on every surface rests on: while a
// text field holds focus it consumes j and k as literal characters, so a
// parent's Keys.onPressed never sees them, while the arrows bubble past it
// and still move the selection.
//
// That claim decided a real change. Settings shipped arrows only, justified
// by a comment saying a "j" typed into one of its text rows had to land in
// the field rather than be stolen as a move — while Arrange, with five real
// text fields, ran the alias and the arrows together without trouble. Only
// one of the two could be right, and nothing executed either. Both shapes are
// driven here instead:
//
//   - a bare inline TextInput, which is what Settings' text rows are, and
//   - the real common/Field.qml, which is what Arrange's five inputs are,
//     symlinked into fixtures/theme-stub/ so this drives the shipped
//     component rather than a copy that could drift away from it. Field adds
//     Keys.onReturnPressed/onEnterPressed/onEscapePressed to its TextInput;
//     that those three handlers do not change what happens to a letter key is
//     exactly the kind of thing worth executing rather than assuming.
//
// No compositor is needed for any of it: neither shape reaches Quickshell, so
// the offscreen platform can instantiate both and QtTest can deliver real key
// events to them.
//
// The one thing this pins that the UI does not quite promise: because a
// focused field swallows j/k, the alias only moves the selection while the
// panel itself holds focus. Settings restores panel focus in onVisibleChanged
// and nowhere else, so after a click into a text row j/k stop moving until
// the window is closed and reopened, and its "↑↓/jk" footer hint is accurate
// only in the panel-focused state. Arrange behaves the same way. The arrows
// keep working throughout, which is what makes the hint's first half true
// unconditionally — see test_arrows_bubble_past_a_focused_field.
import QtQuick
import QtTest
import "fixtures/theme-stub/common"

TestCase {
    id: tc
    name: "FocusGrammar"
    when: windowShown
    visible: true
    width: 400
    height: 300

    property int panelJ: 0
    property int panelK: 0
    property int panelUp: 0
    property int panelDown: 0

    function resetCounts() {
        tc.panelJ = 0;
        tc.panelK = 0;
        tc.panelUp = 0;
        tc.panelDown = 0;
    }

    // Both panels carry the same handler the four shipped surfaces do: named
    // arrow handlers plus a Keys.onPressed aliasing j/k onto them.
    component KeyPanel: Item {
        anchors.fill: parent

        Keys.onUpPressed: tc.panelUp++
        Keys.onDownPressed: tc.panelDown++
        Keys.onPressed: event => {
            if (event.key === Qt.Key_J) {
                tc.panelJ++;
                event.accepted = true;
            } else if (event.key === Qt.Key_K) {
                tc.panelK++;
                event.accepted = true;
            }
        }
    }

    // Settings' shape.
    KeyPanel {
        id: barePanel

        TextInput {
            id: bareInput

            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            verticalAlignment: TextInput.AlignVCenter
            clip: true
            selectByMouse: true
        }
    }

    // Arrange's shape, using the shipped Field.qml itself.
    KeyPanel {
        id: fieldPanel

        Field {
            id: field

            anchors.fill: parent
        }
    }

    // Both surfaces are reached by clicking, so both depend on a click
    // actually moving focus into the input. Neither sets activeFocusOnPress,
    // so both inherit TextInput's default.
    function test_activeFocusOnPress_defaults_true_on_both_shapes() {
        compare(bareInput.activeFocusOnPress, true, "a bare TextInput must take focus on press");
        compare(field.input.activeFocusOnPress, true, "Field's TextInput must take focus on press");
    }

    function test_focused_field_swallows_jk_data() {
        return [
            { tag: "bare TextInput", bare: true },
            { tag: "common/Field.qml", bare: false }
        ];
    }

    // The claim Settings' deleted comment got backwards: a focused field does
    // keep the letters, so aliasing j/k on the panel cannot steal them.
    function test_focused_field_swallows_jk(row) {
        const input = row.bare ? bareInput : field.input;
        resetCounts();
        input.text = "";
        input.forceActiveFocus();
        verify(input.activeFocus, row.tag + " must hold focus");

        keyClick(Qt.Key_J);
        keyClick(Qt.Key_K);

        compare(input.text, "jk", row.tag + " must keep j and k as typed characters");
        compare(tc.panelJ, 0, row.tag + " must not let j reach the panel's alias");
        compare(tc.panelK, 0, row.tag + " must not let k reach the panel's alias");
    }

    function test_arrows_bubble_past_a_focused_field_data() {
        return test_focused_field_swallows_jk_data();
    }

    // The other half, and the reason the arrows are not redundant with the
    // alias: QQuickTextInput ignores Up/Down outright, so they reach the panel
    // even while the field has focus and stay the one way to move from there.
    function test_arrows_bubble_past_a_focused_field(row) {
        const input = row.bare ? bareInput : field.input;
        resetCounts();
        input.text = "";
        input.forceActiveFocus();
        verify(input.activeFocus, row.tag + " must hold focus");

        keyClick(Qt.Key_Up);
        keyClick(Qt.Key_Down);

        compare(tc.panelUp, 1, "Up must bubble past " + row.tag + " to the panel");
        compare(tc.panelDown, 1, "Down must bubble past " + row.tag + " to the panel");
        compare(input.text, "", "an arrow key must not insert a character into " + row.tag);
    }

    function test_panel_focus_lets_jk_through_data() {
        return [
            { tag: "bare TextInput", bare: true },
            { tag: "common/Field.qml", bare: false }
        ];
    }

    // And with the panel itself focused the alias does fire — otherwise the
    // two tests above would pass on a surface where j/k did nothing at all.
    function test_panel_focus_lets_jk_through(row) {
        const panel = row.bare ? barePanel : fieldPanel;
        resetCounts();
        panel.forceActiveFocus();
        verify(panel.activeFocus, "the panel beside " + row.tag + " must hold focus");

        keyClick(Qt.Key_J);
        keyClick(Qt.Key_K);

        compare(tc.panelJ, 1, "j must reach the panel's alias");
        compare(tc.panelK, 1, "k must reach the panel's alias");
    }
}
