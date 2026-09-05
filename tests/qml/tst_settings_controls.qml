// Behaviour of the five control primitives under qml/settings/controls/:
// clicking each one must flip its own state AND emit the signal a
// SettingsRow's caller actually listens for — Toggle.qml's checkbox row
// used to be hand-drawn inline in Settings.qml with nothing pinning either
// half, and lifting it into its own file is the point at which that
// stopped being free.
//
// All five reach only QtQuick, QtQuick.Layouts, common/Pill.qml and Theme —
// no Quickshell type — so qmltestrunner instantiates them directly rather
// than reading them as text.
//
// `when: windowShown` + `visible: true` on the TestCase itself, matching
// tst_focus_grammar.qml's own header: mouseClick needs a real, shown window
// to deliver synthetic events against, which is also why every Component
// below is given an explicit `width` rather than trusting Layout.fillWidth
// (inert here — none of these are hosted inside an actual Layout) or an
// implicitWidth that has nothing yet to become a real `width` from.
import QtQuick
import QtQuick.Layouts
import QtTest
import "fixtures/theme-stub/settings/controls"

TestCase {
    id: testCase
    name: "SettingsControls"
    when: windowShown
    visible: true
    width: 400
    height: 300

    // A Repeater is a zero-sized, non-visual QQuickItem that still occupies
    // a slot in its parent's own `children` array alongside the delegates
    // it creates — so picking a delegate by a fixed index offset from that
    // array is one assumption away from clicking the Repeater itself
    // instead (a click that lands on nothing, and reports the reliable-
    // looking-but-wrong "null" this file's first draft chased). Filtering
    // on `modelData`, a property only a real delegate carries, finds the
    // right item regardless of where among its siblings the Repeater sits.
    function delegatesOf(positioner) {
        return positioner.children.filter(child => child.modelData !== undefined);
    }

    // --- Toggle -------------------------------------------------------

    Component {
        id: toggleOff
        Toggle {
            checked: false
        }
    }

    function test_toggle_click_flips_checked_and_emits_the_new_value() {
        const toggle = createTemporaryObject(toggleOff, testCase);
        verify(toggle !== null);

        let seen = null;
        toggle.toggled.connect(value => seen = value);

        mouseClick(toggle, toggle.width / 2, toggle.height / 2);

        compare(toggle.checked, true, "a click must flip an off Toggle on");
        compare(seen, true, "toggled must carry the new value, not the old one");
    }

    // --- Segmented ------------------------------------------------------

    Component {
        id: segmentedAB
        Segmented {
            width: 200
            options: [{
                    label: "A",
                    value: "a"
                }, {
                    label: "B",
                    value: "b"
                }]
            value: "a"
        }
    }

    function test_clicking_a_segment_activates_its_value() {
        const segmented = createTemporaryObject(segmentedAB, testCase);
        verify(segmented !== null);

        let seen = null;
        segmented.activated.connect(value => seen = value);

        // `track`, the Row that lays the segments out, is Segmented's sole
        // declared child.
        const second = delegatesOf(segmented.children[0])[1];
        verify(second !== undefined, "expected a second segment delegate");
        mouseClick(second, second.width / 2, second.height / 2);

        compare(seen, "b", "clicking the second segment must activate its own value, not the currently active one");
    }

    // --- Slider ---------------------------------------------------------

    Component {
        id: slider0to100
        Slider {
            width: 160
            from: 0
            to: 100
            value: 0
            stepSize: 10
        }
    }

    function test_clicking_the_track_commits_the_clicked_ratio() {
        const slider = createTemporaryObject(slider0to100, testCase);
        verify(slider !== null);

        let seen = null;
        slider.moved.connect(value => seen = value);

        // Half the (explicit, 160px) width is exactly ratio 0.5, which
        // lands on a clean multiple of stepSize (10) for a [0, 100] range —
        // no rounding ambiguity to make the assertion approximate.
        mouseClick(slider, slider.width / 2, slider.height / 2);

        compare(slider.value, 50);
        compare(seen, 50, "moved must carry the committed value");
    }

    function test_clicking_the_left_edge_commits_the_minimum() {
        const slider = createTemporaryObject(slider0to100, testCase);
        verify(slider !== null);

        mouseClick(slider, 1, slider.height / 2);

        compare(slider.value, 0);
    }

    // --- ChipRow ----------------------------------------------------------

    Component {
        id: chipsWifiBluetooth
        ChipRow {
            width: 200
            chips: [{
                    id: "wifi",
                    label: "Wi-Fi"
                }, {
                    id: "bluetooth",
                    label: "Bluetooth"
                }]
            selected: ["wifi"]
        }
    }

    function test_clicking_a_chip_toggles_its_own_id() {
        const chips = createTemporaryObject(chipsWifiBluetooth, testCase);
        verify(chips !== null);

        let seen = null;
        chips.toggled.connect(id => seen = id);

        // ChipRow IS the Flow itself, unlike Segmented's Row one level in.
        const bluetooth = delegatesOf(chips)[1];
        verify(bluetooth !== undefined, "expected a second chip delegate");
        mouseClick(bluetooth, bluetooth.width / 2, bluetooth.height / 2);

        compare(seen, "bluetooth", "clicking a chip must report its own id, regardless of which chips are currently selected");
    }

    // --- Select -----------------------------------------------------------

    Component {
        id: selectTimezones
        Select {
            width: 200
            options: [{
                    label: "UTC",
                    value: "utc"
                }, {
                    label: "CET",
                    value: "cet"
                }]
            value: "utc"
        }
    }

    function test_button_shows_the_current_labels_value() {
        const select = createTemporaryObject(selectTimezones, testCase);
        verify(select !== null);

        compare(select.currentLabel, "UTC");
    }

    function test_clicking_the_button_reveals_the_option_list() {
        const select = createTemporaryObject(selectTimezones, testCase);
        verify(select !== null);

        const button = select.children[0];
        const optionList = select.children[1];

        compare(optionList.visible, false, "the option list must start collapsed");

        mouseClick(button, button.width / 2, button.height / 2);

        compare(select.expanded, true);
        compare(optionList.visible, true, "clicking the button must reveal the option list");
    }

    // Picking an option must both activate it and collapse the list back —
    // leaving it open after a pick would make every subsequent click land
    // on a stale option instead of the button that reopens it.
    function test_picking_an_option_activates_it_and_collapses_the_list() {
        const select = createTemporaryObject(selectTimezones, testCase);
        verify(select !== null);

        let seen = null;
        select.activated.connect(value => seen = value);

        const button = select.children[0];
        mouseClick(button, button.width / 2, button.height / 2);

        // The option list was invisible an instant ago, and Qt Quick does
        // not re-run QtQuick.Layouts geometry for a ColumnLayout that just
        // became visible until a later polish pass — reading a delegate's
        // width in the very same tick this test's other assertions run in
        // reads whatever it was while still collapsed (0), and a 0-wide
        // item accepts no click at all. A short wait gives the layout
        // engine enough real event-loop turns to catch up before this
        // clicks a delegate that has not been sized yet.
        wait(100);

        const optionList = select.children[1];
        const cet = delegatesOf(optionList)[1];
        verify(cet !== undefined, "expected a second option delegate (CET)");
        mouseClick(cet, cet.width / 2, cet.height / 2);

        compare(seen, "cet");
        compare(select.value, "cet");
        compare(select.expanded, false, "picking an option must collapse the list");
    }
}
