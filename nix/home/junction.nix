# Junction (GNOME Circle, github.com/sonnyp/Junction) — not a browser but a
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
# x-scheme-handler/http(s) (+ its x-junction scheme), not text/html — that's
# fine, [Default Applications] entries don't require the type to appear in
# the handler's MimeType line.
{ pkgs, ... }:
let
  junctionDesktop = "re.sonny.Junction.desktop";
in
{
  home.packages = [ pkgs.junction ];

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
