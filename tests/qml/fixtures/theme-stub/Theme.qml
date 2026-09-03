// Stands in for the generated nix/home/quickshell/qml/Theme.qml (a
// Quickshell Singleton pulling in the native plugin, which qmltestrunner
// cannot load — see tests/README.md) so tests can instantiate the real,
// unmodified common/ components directly: Chrome.qml and Panel.qml for
// tst_chrome_geometry.qml, Field.qml for tst_focus_grammar.qml, and the
// file manager's CommandLine.qml for tst_files_cmdline_focus.qml. All of
// them only ever reach QtQuick, QtQuick.Layouts and Theme, nothing
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

    // The file manager's own palette and metrics, for CommandLine.qml. The
    // ints carry the generated file's real values rather than arbitrary
    // ones: the command line's implicitHeight is built out of
    // filesRowHeight and filesCommandHeight, and a test that clicks a row
    // wants the geometry the shipped surface has.
    readonly property color bgDarker: "#15161e"
    readonly property color muted: "#737aa2"
    readonly property color red: "#f7768e"
    readonly property int filesRowHeight: 30
    readonly property int filesIconSize: 16
    readonly property int filesIconColumn: 26
    readonly property int filesPadding: 10
    readonly property int filesRadius: 10
    readonly property int filesCommandHeight: 40
    readonly property int filesGutter: 8
    readonly property int filesRowInset: 8
    readonly property int filesHoverPad: 4
    readonly property int filesHoverPadWide: 6
    readonly property int filesMenuWidth: 220
    readonly property int chromeStripWidth: 3
}
