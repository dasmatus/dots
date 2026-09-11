// Regenerates the GTK 3/4 accent-override stylesheets for the current
// wallpaper accent (tint.rs's gtk_css targets), and keeps the plain
// gtk-icon-theme-name key in gtk-3.0/settings.ini and gtk-4.0/settings.ini
// pointed at whatever Icons.qml just retinted. Both are "write into a GTK
// config file at wallpaper-pick time" jobs, which is why they share this
// file. They do not otherwise interact, and write() below still kicks
// off all four Processes independently, the same "a failure or skip in
// one never blocks the rest" contract Picker.qml's applyAccent() already
// documents for every tint target.
//
// The stylesheets are cheap text, so every pick rewrites both
// unconditionally, the same "always regenerate" call apply_tint_ctx made
// for gtk (unlike Kvantum/icons, which it only redid on an actual accent
// change). They stay written under Theme.tintStateDir, not into
// ~/.config/gtk-3.0 or gtk-4.0: nothing reads an @import of these files
// yet. home.nix's own gtk.theme still pins plain adw-gtk3-dark, and wiring
// the @import is its own later change, not this one. This only has to make
// sure the files exist and stay current so that later wiring is a one-line
// home-manager change instead of also needing a shell-side rewrite too.
//
// The icon-theme name is the opposite case: it has to land in the real
// settings.ini GTK actually reads, because dconf does not. Icons.qml's own
// dconf write of org/gnome/desktop/interface/icon-theme is correct but
// inert on this machine. gsettings-desktop-schemas is not installed, so
// nothing resolves that key back into a GTK setting, and GTK falls back to
// settings.ini, which home-manager otherwise pins to Papirus-Dark forever
// (see nix/home/default.nix's own gtk.iconTheme comment). Writing the same
// 'Papirus-Tint' name here, alongside the existing (harmless, and
// eventually-correct once the schema package is installed) dconf write, is
// what actually reaches GTK apps.
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "tint.js" as Tint
import ".."

Item {
    id: root

    // Same XDG fallback Icons.qml's own dataHome uses: XDG_CONFIG_HOME is
    // set by home-manager's session environment in practice, but a bare
    // XDG-compliant session may not export it.
    readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")

    function write(accent, accentDark, accentLight) {
        // mkdir -p inline rather than depending on Picker's own tint-state
        // mkdir having already run first: each Process here is independent,
        // so an unwritable or missing tint dir fails only this write,
        // whichever of the two happens to run first.
        gtk3.command = ["sh", "-c", 'mkdir -p "$(dirname "$2")" && printf \'%s\' "$1" > "$2"', "_", Tint.gtkCss(accent, accentDark, accentLight, 3), Theme.tintStateDir + "/gtk3.css"];
        gtk3.running = true;

        gtk4.command = ["sh", "-c", 'mkdir -p "$(dirname "$2")" && printf \'%s\' "$1" > "$2"', "_", Tint.gtkCss(accent, accentDark, accentLight, 4), Theme.tintStateDir + "/gtk4.css"];
        gtk4.running = true;

        root.writeIconTheme();
    }

    // Rewrites just the gtk-icon-theme-name= line of each settings.ini,
    // leaving gtk-theme-name and any extraConfig keys exactly as
    // home-manager last rendered them. Unlike the two CSS writes above,
    // this can never blindly overwrite the whole file. It also cannot
    // reuse their plain `>` redirect: settings.ini may still be the
    // read-only-store symlink home-manager used to manage it as, on any
    // machine that has not re-run `home-manager switch` since this landed
    // (nix/home/default.nix now leaves these two paths unmanaged after a
    // one-time seed, precisely so a later edit like this one has somewhere
    // writable to land). `>` opens through a symlink and fails outright
    // against a read-only store target (EROFS, confirmed against a scratch
    // symlink to the same store before committing to this shape); `mv`
    // replaces the directory entry itself instead of writing through
    // whatever it currently points to, which is safe whether the
    // destination is a symlink, an ordinary file, or missing altogether.
    // Reading the current content with `cat`/`grep` has no such problem:
    // following a symlink to read is fine, only the replace has to avoid
    // it. So the script below reads through whatever is there and only
    // ever replaces via `mv`.
    //
    // GTK reads settings.ini once at process startup; this fallback path
    // has no live file-watch the way a running gsettings/dconf consumer
    // would get a change notification through. So this only reaches GTK
    // apps launched after a pick. An already-running one keeps whatever
    // icon theme it started with until it is restarted.
    function writeIconTheme() {
        gtk3Ini.command = ["sh", "-c", root.iconThemeScript, "_", root.configHome + "/gtk-3.0/settings.ini", "Papirus-Tint"];
        gtk3Ini.running = true;

        gtk4Ini.command = ["sh", "-c", root.iconThemeScript, "_", root.configHome + "/gtk-4.0/settings.ini", "Papirus-Tint"];
        gtk4Ini.running = true;
    }

    // Shared by both Ini Processes below, same script, different argv
    // ($1 = destination path, $2 = theme name), so the patch logic exists
    // exactly once. `|| true` on the grep guards the (currently
    // unreachable, since the seed in nix/home/default.nix always writes a
    // [Settings] header first) case where every existing line matches the
    // pattern being dropped: grep's own exit code for "nothing selected"
    // is 1, which set -e would otherwise treat as this whole write failing.
    //
    // Ownership split with nix/home/default.nix's own
    // home.activation.gtkSettingsIniSeed, spelled out because getting it
    // backwards is what caused the bug this guard fixes: the activation
    // seed is the only thing allowed to make settings.ini *exist*. It owns
    // the full rendered content (gtk-theme-name, font settings,
    // extraConfig, all of it). This script only ever owns the single
    // gtk-icon-theme-name= line inside a file that already exists. Before
    // this guard, a missing destination fell into the `else` branch below
    // and got a from-scratch file containing only `[Settings]` and
    // gtk-icon-theme-name=, silently discarding every other key. And
    // because that write leaves a regular file behind, the seed's own
    // `[ -f "$dst" ]` guard would then see it as already installed and skip
    // forever, pinning GTK to built-in Adwaita for good. So: no file, no
    // write, full stop. Let the seed run on the next activation instead.
    readonly property string iconThemeScript: `
set -e
dst=$1; name=$2
[ -e "$dst" ] || exit 0
mkdir -p "$(dirname "$dst")"
tmp=$(mktemp "$dst.XXXXXX")
if [ -s "$dst" ]; then
  grep -v '^gtk-icon-theme-name=' "$dst" > "$tmp" || true
else
  printf '[Settings]\n' > "$tmp"
fi
printf 'gtk-icon-theme-name=%s\n' "$name" >> "$tmp"
mv "$tmp" "$dst"
`

    Process {
        id: gtk3
    }

    Process {
        id: gtk4
    }

    Process {
        id: gtk3Ini
    }

    Process {
        id: gtk4Ini
    }
}
