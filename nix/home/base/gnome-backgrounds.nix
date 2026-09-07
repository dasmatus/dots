# The repo's own wallpapers, registered with GNOME's background chooser.
#
# Copying an image into ~/.local/share/backgrounds does NOT put it in the
# chooser — that directory is only where GNOME Settings drops a copy of a
# picture you added by hand, which is why 31 files sat there while the grid in
# Settings > Appearance still showed nothing but the stock set. The list the
# panel actually renders is assembled by scanning every
# XDG_DATA_DIRS/gnome-background-properties/*.xml, so a wallpaper is "in the
# chooser" exactly when some XML names it and not otherwise.
#
# Like nix/home/base/gnome-extensions.nix, this belongs to the PORTABLE profile
# even though it is GNOME-only: it is for the host this profile is a guest on,
# a Fedora Atomic / secureblue desktop running GNOME. The session profile's
# desktop is Hyprland, where the equivalent surface is quickshell's own picker
# (nix/home/desktop/quickshell/qml/wallpaper/Picker.qml) and this file is inert
# — an unread XML costs one small store path and nothing else.
#
# The <filename> entries point at the STORE copy of Wallpapers/, not at the
# checkout. Coercing the directory once puts the whole tree at a single stable
# path, so the chooser keeps working when the repo is moved, renamed or not yet
# cloned — and the entries cannot rot into a half-broken grid the way absolute
# $HOME paths do. It also keeps evaluation pure: the tree is read with
# builtins.readDir on a source path, never from the live filesystem, so no
# --impure and no IFD. NB every file must be git-tracked to be visible to the
# evaluator; all 65 currently are.
{ lib, ... }:
let
  wallpapers = ../../../Wallpapers;

  # GNOME renders whatever gdk-pixbuf can load. Restricted to the three
  # extensions actually present rather than "every regular file", so a stray
  # README or .license in the tree cannot become a broken tile.
  imageExtensions = [
    "jpg"
    "jpeg"
    "png"
    "svg"
  ];

  isImage = name: lib.any (ext: lib.hasSuffix ".${ext}" (lib.toLower name)) imageExtensions;

  # A RECURSIVE walk, because the tree is not flat: wh/ holds images
  # directly, while misc/ and night/ hold a further level of category
  # directories (misc/abstract, night/os, ...). A one-level scan silently
  # yields only wh/ — 31 of the 65 tracked files — and the omission is
  # invisible in the result, since a short list of wallpapers looks exactly
  # like a correct one.
  collect =
    prefix: dir:
    lib.concatLists (
      lib.mapAttrsToList (
        name: type:
        let
          rel = if prefix == "" then name else "${prefix}/${name}";
        in
        if type == "directory" then
          collect rel (dir + "/${name}")
        else if (type == "regular" || type == "symlink") && isImage name then
          [
            {
              inherit name;
              collection = prefix;
              path = rel;
            }
          ]
        else
          [ ]
      ) (builtins.readDir dir)
    );

  entries = collect "" wallpapers;

  # "wh/wallhaven-1q2okg.jpg" -> "wh · wallhaven-1q2okg". The collection is
  # kept in the label because the three directories are the only thing
  # distinguishing otherwise interchangeable wallhaven-<id> names.
  labelOf =
    e:
    "${lib.replaceStrings [ "/" ] [ " · " ] e.collection} · ${lib.head (lib.splitString "." e.name)}";

  # zoom (fill, cropping to aspect) rather than scaled/centered: these are
  # desktop-resolution photographs, and GNOME's own adwaita.xml uses zoom for
  # the same reason. pcolor/scolor only show through for images that do not
  # cover the screen, which zoom guarantees they do; black is the neutral
  # choice behind a dark desktop.
  wallpaperElement = e: ''
    <wallpaper deleted="false">
      <name>${lib.escapeXML (labelOf e)}</name>
      <filename>${wallpapers}/${e.path}</filename>
      <options>zoom</options>
      <shade_type>solid</shade_type>
      <pcolor>#000000</pcolor>
      <scolor>#000000</scolor>
    </wallpaper>'';
in
{
  xdg.dataFile."gnome-background-properties/dots-wallpapers.xml".text = ''
    <?xml version="1.0"?>
    <!DOCTYPE wallpapers SYSTEM "gnome-wp-list.dtd">
    <wallpapers>
    ${lib.concatStringsSep "\n" (map wallpaperElement entries)}
    </wallpapers>
  '';
}
