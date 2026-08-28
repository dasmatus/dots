// Stands in for the generated nix/home/quickshell/qml/Theme.qml (a
// Quickshell Singleton pulling in the native plugin, which qmltestrunner
// cannot load — see tests/README.md) so tst_chrome_geometry.qml can
// instantiate the real, unmodified Chrome.qml and Panel.qml directly:
// both only ever reach QtQuick, QtQuick.Layouts and Theme, nothing
// Quickshell-specific. The sibling qmldir declares this as a singleton up
// front — without it the engine still resolves `pragma Singleton` on its
// own, but only after a first pass where every Theme.* reference reads
// undefined, which is noisy rather than wrong.
pragma Singleton
import QtQuick

QtObject {
    readonly property color accent: "#7aa2f7"
    readonly property color fg: "#c0caf5"
    readonly property color bg: "#1a1b26"
    readonly property string fontUi: "sans-serif"
    readonly property string alphaPanel: "e6"
    readonly property int launcherRadius: 10
}
