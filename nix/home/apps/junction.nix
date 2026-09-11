# Junction (GNOME Circle, github.com/sonnyp/Junction), not a browser but a
# browser chooser: it registers as the default URL handler and pops up an
# application picker for every clicked link, forwarding per click to Brave or
# LibreWolf (both native modules next door). nixpkgs' junction 1.12 is a
# GJS/GTK4/libadwaita app; the binary is re.sonny.Junction (meta.mainProgram),
# present at the exact nixpkgs rev pinned in flake.lock.
#
# "Default browser" on Linux is nothing but mimeapps.list associations.
# Upstream's advice (`xdg-settings set default-web-browser
# re.sonny.Junction.desktop`) writes exactly the entries below; xdg.mimeApps
# declares them instead. Junction's .desktop only advertises
# x-scheme-handler/http(s) (+ its x-junction scheme), not text/html. That's
# fine, since [Default Applications] entries don't require the type to
# appear in the handler's MimeType line.
#
# Junction is a FLATPAK now (re.sonny.Junction, declared in
# nix/home/base/flatpaks.nix), so this module installs no package. It only
# owns the mimeapps associations that make the chooser the default handler.
# The desktop-entry id is unchanged: flatpak exports its entry under the app
# id, `re.sonny.Junction.desktop`, which is exactly the name the nixpkgs
# package used, so every association below keeps resolving.
{ ... }:
let
  junctionDesktop = "re.sonny.Junction.desktop";
in
{
  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      "text/html" = junctionDesktop;
      "application/xhtml+xml" = junctionDesktop;
      "x-scheme-handler/http" = junctionDesktop;
      "x-scheme-handler/https" = junctionDesktop;
    };
  };

  # GNOME and every browser's "set as default" prompt rewrite
  # ~/.config/mimeapps.list imperatively at runtime; without force the very
  # first switch aborts on the pre-existing unmanaged file, and any later
  # runtime rewrite would clobber-block again. Force makes the declarative
  # copy win on every switch.
  xdg.configFile."mimeapps.list".force = true;
}
