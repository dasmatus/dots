// Stands in for the generated nix/home/desktop/quickshell/qml/Theme.qml (a
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

    // Added for tst_settings_controls.qml: Toggle.qml and Slider.qml both
    // read this for their unchecked/at-rest fill, and neither one had a
    // stub test to need it before.
    readonly property color selection: "#3b4261"
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
    readonly property int filesCrumbMenuCap: 15
    readonly property int chromeStripWidth: 3

    // The raised-surface token task 5's contrast fix-round added to
    // nix/data/palette.json: a fill for a band that needs to read as lifted off
    // its darker neighbour by roughly the same margin the deleted
    // Theme.border lines once gave for free.
    readonly property color raised: "#3d4463"

    // Bar geometry the workspace icon-list would need if a future test ever
    // instantiates it directly. Not exercised by any test today — the real
    // component reaches Hyprland and DesktopEntries, both Quickshell
    // singletons this stub cannot stand in for — but every generated Theme
    // token gets mirrored here on principle, so a later test that does
    // reach for one is never blocked on this file catching up first.
    readonly property int barHeight: 30
    readonly property int barFontSize: 15
    readonly property int barPillPadding: 14
    readonly property int barIconSize: 20
    readonly property int barWorkspaceIconCap: 4
    readonly property int barPillSpacing: 6

    // Settings panel geometry, mirrored from the generated Theme.qml on the
    // same principle as the bar tokens above: not exercised by any test
    // today (the richer sidebar-nav layout lands in a later task) but kept
    // in step so that task is never blocked on this stub catching up.
    // settingsTitleFontSize and friends stay `real`, matching
    // font.pointSize's own type, the same distinction barFontSize's `int`
    // makes for font.pixelSize above.
    readonly property int settingsSidebarWidth: 260
    readonly property int settingsHeaderHeight: 64
    readonly property int settingsSearchHeight: 40
    readonly property int settingsRowHeight: 56
    readonly property int settingsRowPadding: 16
    readonly property int settingsRowGap: 2
    readonly property int settingsGroupGap: 32
    readonly property int settingsControlColumn: 320
    readonly property int settingsRadius: 10
    readonly property int settingsIconSize: 20
    readonly property real settingsPanelWidthFactor: 0.72
    readonly property real settingsPanelHeightFactor: 0.8
    readonly property real settingsTitleFontSize: 24
    readonly property real settingsGroupFontSize: 11
    readonly property real settingsRowTitleFontSize: 14
    readonly property real settingsRowDescFontSize: 11
    readonly property real settingsNavFontSize: 13
    readonly property int settingsFooterHeight: 40
    readonly property int settingsToggleWidth: 44
    readonly property int settingsToggleHeight: 24
}
