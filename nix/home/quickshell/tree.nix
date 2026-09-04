# Assembles the Quickshell config directory: the checked-in QML under qml/,
# plus a Theme.qml generated from nix/palette.json.
#
# Generating rather than hand-writing the palette keeps nix/palette.json the
# one place colours are defined: this file is what reads it, with
# builtins.fromJSON, and flake/checks.nix's palette-eval check reads the same
# JSON back to assert the generated Theme.qml actually carries it. A
# hand-copied QML palette would be a sixth source of truth, which is the exact
# problem docs/superpowers/specs/2026-08-23-system-palette-single-source-design.md
# exists to stop.
#
# Split out of default.nix as a plain function so flake/packages.nix can build
# the same tree for the qmllint gate. A home-manager module cannot be
# evaluated from the flake's package set, but this can.
#
# Neutrals, fonts and metrics are baked in at build time. The accent is not:
# Picker.qml (and Rotation.qml's hourly pick through it) derives it from the
# current wallpaper and rewrites tint/current.json, which Theme.qml watches,
# so a wallpaper change repaints the shell with no home-manager switch.
{
  pkgs,
  stateHome,
  cacheHome,
  quicklinks ? [ ],
  snippets ? [ ],
  keybinds ? [ ],
}:
let
  inherit (pkgs) lib;

  palette = builtins.fromJSON (builtins.readFile ../../palette.json);

  # Named for the shell rather than for wallpaper-tui: Picker.qml is what
  # writes this file now. One Nix binding used on both the writer's
  # (Theme.tintStatePath) and the watcher's (tintState.path) side below is
  # what keeps the two from disagreeing about where it lives — see this
  # module's own header for what happens when they do.
  tintStateDir = "${stateHome}/dots-shell/tint";

  # Same one-binding-feeds-both-sides reasoning as tintStateDir above: the
  # writer that records frecency and any future watcher that reloads it must
  # not be able to disagree about where frecency.json lives.
  launcherStateDir = "${stateHome}/dots-shell/launcher";

  # The file manager's prebuilt search index, written by the
  # dots-files-index unit (files-index.nix) and read by files/Files.qml.
  # Same one-binding-feeds-both-sides rule as the two above, and it matters
  # more here than for either: the writer is a systemd unit in a different
  # file, so a disagreement about the path would not fail to build, it
  # would just make `/` quietly fall back to walking the tree forever.
  #
  # Cache rather than state: the whole file is derived from the filesystem
  # and is rebuilt from scratch every ten minutes, so losing it costs one
  # walk and nothing else.
  filesIndexDir = "${cacheHome}/dots-shell/files";

  # Double-quoted, not an indented string: Nix strips the common indentation
  # off a '' '' literal, which would flatten every one of these to column 0.
  colorProperties = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      name: value: "    readonly property color ${name}: \"${value}\";"
    ) palette.colors
  );

  # Papirus's folder-colour name -> hex map. nearestPapirusColor (tint.js)
  # takes this table as a parameter rather than reading the file itself: a
  # `.pragma library` script cannot read a file or a singleton on its own,
  # so the table has to reach it through the papirusColors property below.
  # The runCommand assertion further down reads this same parsed value
  # rather than re-deriving the name list by scraping.
  papirusColors = builtins.fromJSON (builtins.readFile ./qml/wallpaper/papirus-colors.json);

  # Same reasoning as colorProperties above, with the indent hardcoded one
  # level deeper: these entries sit inside the object literal the
  # papirusColors property wraps, not directly inside Singleton { }. The
  # interpolation site below carries no static indent of its own precisely
  # so this hardcoded prefix is the only one applied — a nonzero static
  # prefix there would land on this string's first line only, since a '' ''
  # literal dedents its own source lines before substituting, not after.
  papirusColorEntries = lib.concatStringsSep ",\n" (
    lib.mapAttrsToList (name: value: "        \"${name}\": \"${value}\"") papirusColors
  );

  # Both the papirusBase property and the runCommand assertion below need
  # this path; one binding keeps them from drifting apart.
  papirusIconThemeBase = "${pkgs.papirus-icon-theme}/share/icons/Papirus-Dark";

  # The sizes Papirus-Tint actually ships — the one place this list is
  # written down. Everything else that needs it (index.theme's Directories
  # key below, and Icons.qml's retint() through the papirusTintSizes QML
  # property) derives from this list rather than hardcoding its own copy, so
  # adding a size later is a one-line change here instead of a copy-pasted
  # block in two languages.
  papirusTintSizes = [
    22
    24
    32
    48
    64
  ];

  papirusTintDirectories = lib.concatMapStringsSep "," (
    size: "${toString size}x${toString size}/places"
  ) papirusTintSizes;

  # The same sizes as space-separated "<n>x<n>" tokens, for Icons.qml's
  # retint() to iterate over as argv rather than hardcoding a second literal
  # size list in a second language — see the papirusTintSizes QML property
  # below.
  papirusTintSizeTokens = lib.concatMapStringsSep " " (
    size: "${toString size}x${toString size}"
  ) papirusTintSizes;

  papirusTintSections = lib.concatMapStringsSep "\n\n" (size: ''
    [${toString size}x${toString size}/places]
    Size=${toString size}
    Context=Places
    Type=Fixed'') papirusTintSizes;

  # The runtime tint theme Icons.qml assembles into: Papirus-Dark with its
  # folder icons re-symlinked to the wallpaper accent. THIN on purpose — it
  # ships only the five `places` directories below, and Inherits resolves
  # every other icon straight from papirusIconThemeBase, so nothing else
  # needs copying or regenerating when the accent changes.
  papirusTintIndexFile = pkgs.writeText "index.theme" ''
    [Icon Theme]
    Name=Papirus-Tint
    Comment=Papirus-Dark with folder icons recoloured to the wallpaper accent
    Inherits=Papirus-Dark,Papirus,hicolor
    Directories=${papirusTintDirectories}

    ${papirusTintSections}
  '';

  # Named Theme, not Palette: QtQuick already exports a Palette type, and a
  # singleton of that name resolves to QQuickPalette instead of this one, so
  # every Theme.bg would silently read a property that does not exist.
  themeQml = ''
    pragma Singleton

    // Generated by nix/home/quickshell/tree.nix from nix/palette.json.
    // Edit the JSON, not this file: this one is rebuilt on every switch.
    //
    // QtQuick is imported for the `color` property type, which is a QtQuick
    // basic type rather than a Quickshell one.
    import QtQuick
    import Quickshell
    import Quickshell.Io

    Singleton {
    ${colorProperties}

        readonly property string fontUi: "${palette.fonts.ui}";
        readonly property string fontMono: "${palette.fonts.mono}";
        readonly property int fontSize: ${toString palette.fonts.size};

        // Bar geometry, kept beside the colours for the same reason the
        // launcher's metrics are: waybar's stylesheet had them as CSS
        // literals, which is where a "why is this 30 and that 32" afternoon
        // comes from.
        readonly property int barHeight: ${toString palette.bar.height};
        readonly property int barSpacing: ${toString palette.bar.spacing};
        readonly property int barFontSize: ${toString palette.bar.fontSize};
        readonly property int barPillPadding: ${toString palette.bar.pillPadding};
        readonly property int barIconSize: ${toString palette.bar.iconSize};
        readonly property int barTitleMaxWidth: ${toString palette.bar.titleMaxWidth};

        // How many app icons a single crowded workspace draws before the
        // rest fold into a "+n" badge — see Workspaces.qml's own use of it
        // for why an unbounded row would be able to push the clock off the
        // bar.
        readonly property int barWorkspaceIconCap: ${toString palette.bar.workspaceIconCap};

        // Launcher geometry, still read from the palette's `beamenu` block.
        // The values outlive the program they were named for, so the key is
        // renamed when that crate goes rather than duplicated now.
        readonly property int launcherLines: ${toString palette.beamenu.lines};
        readonly property real launcherWidthFactor: ${toString palette.beamenu.widthFactor};
        readonly property int launcherIconSize: ${toString palette.beamenu.iconSize};
        readonly property int launcherLineHeight: ${toString palette.beamenu.lineHeight};
        readonly property int launcherSearchHeight: ${toString palette.beamenu.searchHeight};
        readonly property int launcherRadius: ${toString palette.beamenu.radius};
        readonly property int launcherPreviewWidth: ${toString palette.beamenu.previewWidth};

        // File-manager geometry. Its own block rather than reused launcher
        // metrics: the two disagree on every one of them, and a shared
        // constant that both callers immediately override is the magic
        // number this file exists to stop.
        readonly property int filesTabHeight: ${toString palette.files.tabHeight};
        readonly property int filesTabPadding: ${toString palette.files.tabPadding};
        readonly property int filesTabIndicator: ${toString palette.files.tabIndicator};
        readonly property int filesRowHeight: ${toString palette.files.rowHeight};
        readonly property int filesIconSize: ${toString palette.files.iconSize};
        readonly property int filesIconColumn: ${toString palette.files.iconColumn};
        readonly property int filesSidebarWidth: ${toString palette.files.sidebarWidth};
        readonly property int filesGutter: ${toString palette.files.gutter};
        readonly property int filesPadding: ${toString palette.files.padding};
        readonly property int filesRadius: ${toString palette.files.radius};
        readonly property int filesSizeColumn: ${toString palette.files.sizeColumn};
        readonly property int filesTimeColumn: ${toString palette.files.timeColumn};
        readonly property int filesCommandHeight: ${toString palette.files.commandHeight};
        readonly property int filesRowInset: ${toString palette.files.rowInset};
        readonly property int filesHoverPad: ${toString palette.files.hoverPad};
        readonly property int filesHoverPadWide: ${toString palette.files.hoverPadWide};
        readonly property int filesMenuWidth: ${toString palette.files.menuWidth};

        // How many entries a crumb's dropdown shows before it cuts off and
        // reports the rest as a count instead — see files/crumbmenu.js's own
        // comment for why a directory like /nix/store forces a cap at all.
        // 15 is chosen against filesRowHeight: 15 entries plus the fixed
        // open-this-folder row and, when the cap bites, the one-line
        // remainder trailer come to 17 rows, or ~530px including padding,
        // comfortably inside this file manager's own 700px window with
        // headroom left for PopupShell's flip-above-the-anchor case.
        readonly property int filesCrumbMenuCap: ${toString palette.files.crumbMenuCap};

        // Accent edge-strip geometry, its own top-level palette block since
        // it belongs to no single component the way the file manager's
        // metrics do.
        readonly property int chromeStripWidth: ${toString palette.chrome.stripWidth};

        // Alpha suffixes are applied at the seam by each consumer, so they stay
        // strings here rather than being folded into the colours above.
        readonly property string alphaPanel: "${palette.alpha.panel}";
        readonly property string alphaHeading: "${palette.alpha.heading}";

        readonly property color accentFallback: "${palette.accentFallback}";

        // The Nix-store Kvantum theme Kvantum.qml's retint() copies from —
        // the same store path the deleted wallpaper-tui.nix wrapper passed
        // in as WALLPAPER_TUI_KVANTUM_BASE. Read-only for the same reason
        // every store path here is: it ships as part of the Nix store,
        // which is immutable by design.
        readonly property string kvantumBase: "${pkgs.catppuccin-kvantum}/share/Kvantum/catppuccin-frappe-blue";

        // The Nix-store Papirus-Dark tree Icons.qml's retint() copies from.
        // Papirus-Dark/<size> are symlinks to ../Papirus/<size>, so whole
        // size directories are shared with the light variant — a copy out
        // of this path has to dereference the symlinks rather than copy
        // them as-is.
        readonly property string papirusBase: "${papirusIconThemeBase}";

        // The upstream script that points a folder's plain icon name at its
        // colour-suffixed variant by symlink, e.g. folder.svg ->
        // folder-red.svg. Icons.qml's retint() drives it with the accent
        // nearestPapirusColor (tint.js) resolves.
        readonly property string papirusFolders: "${pkgs.papirus-folders}/bin/papirus-folders";

        // Papirus's folder-colour name -> hex map, parsed from
        // qml/wallpaper/papirus-colors.json so nearestPapirusColor (tint.js)
        // reads the same table this file's own build-time assertion checks.
        // Wrapped in parens: a bare `{` in a QML binding opens a code block,
        // not an object literal.
        readonly property var papirusColors: ({
    ${papirusColorEntries}
        });

        // A generated index.theme for the runtime Papirus-Tint theme. THIN
        // on purpose: it ships only the five <size>/places directories
        // listed under its own Directories key, and Inherits resolves every
        // other icon straight from the Papirus-Dark store theme, so nothing
        // else needs copying or regenerating when the wallpaper accent
        // changes.
        readonly property string papirusTintIndex: "${papirusTintIndexFile}";

        // The sizes above, as space-separated "<n>x<n>" tokens
        // ("22x22 24x24 ..."), matching papirusTintIndex's own Directories
        // key one-for-one because both are generated from the same
        // papirusTintSizes list in this file. Icons.qml's retint() reads
        // this rather than hardcoding the list a second time in shell, so
        // adding a size is one edit here instead of two edits in two
        // languages.
        readonly property string papirusTintSizes: "${papirusTintSizeTokens}";

        // Picker.qml mkdir -p's this before every write; exposed as its own
        // property rather than derived by trimming tintStatePath in JS so
        // there is exactly one place that knows the directory ends in
        // "/current.json".
        readonly property string tintStateDir: "${tintStateDir}";
        readonly property string tintStatePath: "${tintStateDir}/current.json";

        // Mirrors tintStateDir/tintStatePath above: the launcher's frecency
        // writer mkdir -p's launcherStateDir before writing
        // launcherStatePath, so the two can never disagree about where
        // frecency.json lives.
        readonly property string launcherStateDir: "${launcherStateDir}";
        readonly property string launcherStatePath: "${launcherStateDir}/frecency.json";

        // Two files from one walk, not one filtered at query time. Pruning
        // dotfiles is the difference between a 0.24s and a 0.89s walk, so
        // files-index.nix does it once when it builds and files/index.js
        // picks a file rather than paying for a filter on every keystroke.
        readonly property string filesIndexAll: "${filesIndexDir}/all.tsv";
        readonly property string filesIndexVisible: "${filesIndexDir}/visible.tsv";

        // Quickshell's qmltypes gives FileView.adapter the type FileViewAdapter
        // without exporting it, so qmllint cannot resolve anything reached
        // through it — that is why the category is suppressed here. Separately,
        // JsonAdapter has no `root` property on this Quickshell build: only a
        // property DECLARED on the adapter instance gets populated from the
        // file, which is why `accent` below is declared directly on tintState's
        // adapter rather than read off a `root` that does not exist.
        // qmllint disable unresolved-type

        // A missing file, an unreadable one and a null accent all land on the
        // fallback. The shell has to paint before any wallpaper has ever been
        // set, which is the state a fresh install boots into.
        readonly property color accent: {
            const live = tintState.adapter.accent;
            return live ? live : accentFallback;
        }

        FileView {
            id: tintState

            path: "${tintStateDir}/current.json"
            watchChanges: true
            onFileChanged: reload()
            adapter: JsonAdapter {
                property var accent: null
            }
        }
        // qmllint enable unresolved-type
    }
  '';

  themeFile = pkgs.writeText "Theme.qml" themeQml;

  # Quickshell finds singletons by scanning for `pragma Singleton` and needs no
  # qmldir. qmllint does need one: without the declaration it types `Theme` as
  # the component rather than the instance, so every Theme.bg reads as a
  # missing property and the warnings that matter get lost in the noise.
  qmldirFile = pkgs.writeText "qmldir" ''
    singleton Theme 1.0 Theme.qml
  '';
  # The launcher's user data. $XDG_CONFIG_HOME/quickshell is a symlink to this
  # store path, so nothing can be dropped alongside it at runtime; generating
  # these into the tree keeps them declarative and keeps the launcher reading
  # one location rather than two.
  # Wrapped in an object rather than written as a bare array: JsonAdapter
  # refuses a non-object root with "Failed to deserialize json: not an object",
  # and it says so in the log rather than at load, so a bare array yields a
  # provider that silently returns nothing.
  quicklinksFile = pkgs.writeText "quicklinks.json" (builtins.toJSON { items = quicklinks; });
  snippetsFile = pkgs.writeText "snippets.json" (builtins.toJSON { items = snippets; });
  keybindsFile = pkgs.writeText "keybinds.json" (builtins.toJSON { groups = keybinds; });
in
pkgs.runCommand "dots-quickshell-config" { } ''
  mkdir -p "$out"
  cp -r ${./qml}/. "$out/"
  chmod -R u+w "$out"
  cp ${themeFile} "$out/Theme.qml"
  cp ${qmldirFile} "$out/qmldir"
  cp ${quicklinksFile} "$out/launcher/quicklinks.json"
  cp ${snippetsFile} "$out/launcher/snippets.json"
  cp ${keybindsFile} "$out/cheatsheet/keybinds.json"

  # A Papirus release that renames or drops a folder colour would otherwise
  # leave nearestPapirusColor (tint.js) picking a name that resolves to
  # nothing at runtime. Fail the build loudly instead, checking every name
  # papirusColors above was parsed from against the store theme it names.
  for name in ${lib.concatStringsSep " " (builtins.attrNames papirusColors)}; do
    if [ ! -e "${papirusIconThemeBase}/24x24/places/folder-$name.svg" ]; then
      echo "papirus-colors.json has '$name' but Papirus ships no folder-$name.svg" >&2
      exit 1
    fi
  done
''
