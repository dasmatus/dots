// Reachability test: proves the wallpaper apply path actually CALLS each
// tint writer, not just that the writers are correct in isolation
// (tst_tint.qml) or agree with the crate (tst_tint_parity.qml).
//
// Motivating bug: hyprlandBorderCommands, gtkCss and recolorKvantumText
// were ported and unit-tested with zero call sites anywhere outside
// tint.js — every unit test on the writers themselves stayed green through
// that, because none of them ever look at the caller. Only a test on the
// caller can catch a future edit that unwires one again.
//
// qmltestrunner cannot instantiate Picker.qml, Borders.qml, Gtk.qml or
// Kvantum.qml — all reach Quickshell.Io's Process, and per tests/README.md
// "qmltestrunner cannot instantiate a component that inherits a Quickshell
// type" — so this reads the shipped QML source as text instead, the same
// XHR idiom tst_monitor_parity.qml uses for its fixtures.
import QtQuick
import QtTest

TestCase {
    name: "TintWiring"

    function readSource(relPath) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl(relPath), false);
        xhr.send();
        compare(xhr.status, 200, relPath + " must be readable (needs QML_XHR_ALLOW_FILE_READ=1)");
        return xhr.responseText;
    }

    // Slices out applyAccent()'s own body, so a call site sitting anywhere
    // ELSE in the file (a comment, a dead helper) cannot satisfy this test.
    function applyAccentBody() {
        const picker = readSource("../../nix/home/quickshell/qml/wallpaper/Picker.qml");
        const start = picker.indexOf("function applyAccent(");
        verify(start !== -1, "Picker.qml must define applyAccent(triple)");
        const end = picker.indexOf("\n    }", start);
        verify(end !== -1, "applyAccent(triple)'s closing brace must be found");
        return picker.slice(start, end);
    }

    function test_apply_accent_calls_every_tint_target() {
        const body = applyAccentBody();

        verify(body.indexOf("icons.retint(") !== -1, "icon retint must stay wired");
        verify(body.indexOf("borders.apply(") !== -1, "Hyprland border tint is unwired");
        verify(body.indexOf("gtk.write(") !== -1, "GTK stylesheet tint is unwired");
        verify(body.indexOf("kvantum.retint(") !== -1, "Kvantum tint is unwired");
    }

    function test_picker_instantiates_every_tint_target() {
        const picker = readSource("../../nix/home/quickshell/qml/wallpaper/Picker.qml");

        verify(picker.indexOf("Icons {") !== -1, "Picker.qml must instantiate Icons");
        verify(picker.indexOf("Borders {") !== -1, "Picker.qml must instantiate Borders");
        verify(picker.indexOf("Gtk {") !== -1, "Picker.qml must instantiate Gtk");
        verify(picker.indexOf("Kvantum {") !== -1, "Picker.qml must instantiate Kvantum");
    }

    function test_border_target_calls_the_ported_writer() {
        const src = readSource("../../nix/home/quickshell/qml/wallpaper/Borders.qml");
        verify(src.indexOf("Tint.hyprlandBorderCommands(") !== -1, "Borders.qml must call the ported hyprlandBorderCommands, not hand-roll hyprctl argv");
    }

    function test_gtk_target_calls_the_ported_writer() {
        const src = readSource("../../nix/home/quickshell/qml/wallpaper/Gtk.qml");
        verify(src.indexOf("Tint.gtkCss(") !== -1, "Gtk.qml must call the ported gtkCss, not hand-roll the stylesheet");
    }

    function test_kvantum_target_calls_the_ported_writer() {
        const src = readSource("../../nix/home/quickshell/qml/wallpaper/Kvantum.qml");
        verify(src.indexOf("Tint.recolorKvantumText(") !== -1, "Kvantum.qml must call the ported recolorKvantumText, not hand-roll the regex");
    }
}
