// Stands in for the generated nix/home/quickshell/qml/Theme.qml (a
// Quickshell Singleton pulling in the native plugin, which qmltestrunner
// cannot load — see tests/README.md) so tests can instantiate the real,
// unmodified common/ components directly: Chrome.qml and Panel.qml for
// tst_chrome_geometry.qml, Field.qml for tst_focus_grammar.qml. All three
// only ever reach QtQuick, QtQuick.Layouts and Theme, nothing
// Quickshell-specific. The sibling qmldir declares this as a singleton up
// front — without it the engine still resolves `pragma Singleton` on its
// own, but only after a first pass where every Theme.* reference reads
// undefined, which is noisy rather than wrong.
//
// Values are arbitrary but the types are not: `color` and `int` here match
// the generated file's own declarations, so a component binding one of these
// to a typed property behaves the same as it does in the shipped tree.
pragma Singleton
import QtQuick

QtObject {
    readonly property color accent: "#7aa2f7"
    readonly property color fg: "#c0caf5"
    readonly property color bg: "#1a1b26"
    readonly property color bgDark: "#16161e"
    readonly property color border: "#292e42"
    readonly property string fontUi: "sans-serif"
    readonly property string fontMono: "monospace"
    readonly property int fontSize: 12
    readonly property string alphaPanel: "e6"
    readonly property int launcherRadius: 10
}
