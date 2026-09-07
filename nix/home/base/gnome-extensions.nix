# GNOME Shell extensions, installed and enabled declaratively.
#
# These belong to the PORTABLE profile, not the session one, because they are
# for the host this profile is a guest on: a Fedora Atomic / secureblue
# desktop running GNOME. nix/home/profiles/session.nix is the Hyprland half,
# and Hyprland has no shell extensions — the equivalent surface there is the
# Quickshell tree.
#
# They are installed unconditionally rather than gated on `settings.desktop`,
# which would be the wrong switch twice over: that key describes the NixOS
# system this repo builds (it reads "hyprland"), not the foreign host the
# portable profile is applied to, so gating on it would disable these on
# precisely the machine they exist for. An extension that GNOME Shell never
# loads costs a package in the profile and nothing else — there is no unit,
# no daemon and no autostart involved.
#
# How a nix-installed extension is found at all: GNOME Shell scans
# XDG_DATA_DIRS for share/gnome-shell/extensions/<uuid>. On NixOS that
# includes the home profile already; on a foreign host it does NOT until
# `targets.genericLinux.enable` prepends it, which flake/home.nix sets for
# exactly this class of reason. Without that, every extension below installs
# correctly and is then invisible to the running Shell.
#
# UUIDs are read off the packages (`extensionUuid`) rather than written out by
# hand, so a rename upstream cannot leave `enabled-extensions` pointing at a
# string nothing provides — the failure mode where the extension is installed,
# the dconf key looks right, and the Shell silently loads nothing.
{ pkgs, chromaleon, ... }:
let
  extensions =
    with pkgs.gnomeExtensions;
    [
      # A macOS-style dock. One of the two extensions here that are purely a
      # preference rather than a capability — blur-my-shell below is the other,
      # and the two are listed adjacent because they interact.
      dash-to-dock

      # Blur behind the top panel, the overview and the dash.
      #
      # Next to dash-to-dock on purpose: blur-my-shell ships a dash-to-dock
      # specific blur component, which is dormant unless that extension is also
      # loaded. Dropping dash-to-dock therefore silently changes what this one
      # does, so neither should be removed without looking at the other.
      #
      # Checked against the pinned nixpkgs rather than assumed: `pname` is unique
      # across all 1924 entries in that revision's extensions.json, so the bare
      # attribute resolves with no collision suffix, and its shell_version_map
      # carries a "50" key — required, since this host runs GNOME Shell 50 and an
      # extension whose metadata.json omits the running version installs cleanly
      # and then never loads. Only about a third of that revision's extensions
      # declare 50 at all, so this is a real check rather than a formality.
      blur-my-shell

      # AppIndicator / KStatusNotifierItem / legacy tray support. GNOME dropped
      # the tray protocol upstream, so without this any app whose "keep running
      # in the background" story is a tray icon — the mail client, the vault
      # client, the chat clients — simply has no way to stay reachable with its
      # window closed. That makes this the load-bearing one for the flatpak set
      # in nix/home/base/flatpaks.nix.
      appindicator

      # KDE Connect for GNOME: phone pairing, shared clipboard, notification
      # mirroring, remote input.
      #
      # NB it needs inbound TCP/UDP 1716-1764 to pair, and that is a
      # SYSTEM-level firewall rule this user-scope module cannot open. On the
      # NixOS side that would be `programs.kdeconnect.enable`; on a foreign
      # host it is the host's own firewall (firewalld on Fedora Atomic).
      # Everything else works without it — only discovery and pairing break.
      gsconnect

      # Moves maximized and fullscreen windows onto their own empty workspace,
      # per monitor.
      screentospace

      # Clock to the right-hand side of the panel.
      #
      # `moveclock` (moveclock@kuvaus.org), NOT `move-clock`
      # (Move_Clock@rmy.pobox.com): the two attribute names differ by a hyphen
      # and do opposite things — the hyphenated one moves the clock to the LEFT
      # of the status menu. Checked against each package's own description
      # rather than inferred from the name.
      moveclock

      # Notification banners in a corner instead of GNOME's hard-coded top
      # centre. There is no gsettings key for this — Shell positions the banner
      # in its own layout code — so a corner placement needs an extension or
      # nothing.
      #
      # `notification-banner-position` (notification-position@drugo.dev), NOT
      # `notification-banner-reloaded`. The two do the same job and the latter is
      # the better-known one, but in the pinned nixpkgs its metadata.json stops
      # at shell-version 49 while this host runs 50 — it would install correctly,
      # be listed in enabled-extensions, and never load. That is exactly the
      # silent failure this file's header describes, and it is why the choice was
      # made by reading each candidate's shell-version list rather than by
      # reputation.
      notification-banner-position
    ]
    ++ [
      # ChromaLeon, from this flake rather than nixpkgs (see
      # nix/packages/chromaleon.nix for why it cannot come from
      # pkgs.gnomeExtensions). Outside the `with` block above deliberately: it is
      # not an attribute of that set, and putting it inside would read as though
      # it were.
      #
      # Accent colours only. Its icon engine is pinned off below, because that
      # engine is Adwaita-only and this host runs Papirus-Dark.
      #
      # The non-collision with the repo's own Papirus-Tint pipeline
      # (nix/home/desktop/quickshell/qml/wallpaper/Icons.qml) is environmental,
      # not structural: quickshell reaches only the session profile and GNOME
      # Shell only the portable one, so the two writers of
      # org/gnome/desktop/interface/icon-theme never run in the same session. If
      # the Hyprland host ever gains a GNOME session option they would race over
      # that key, and this is the comment that should stop it being a surprise.
      chromaleon
    ];
in
{
  home.packages = extensions;

  # GNOME Shell reads the enabled set from dconf, so installing the packages
  # is only half the job — an extension present in the profile but absent from
  # this list is shipped and dormant.
  # Panel layout. Both keys belong to extensions above, so they live here
  # rather than in portable.nix's dconf block — an extension's settings are
  # meaningless without the extension, and splitting them would let one be
  # removed without the other.
  dconf.settings."org/gnome/shell/extensions/moveclock" = {
    # Clock LEFT of the quick-settings menu, so the system menu sits in the
    # corner. moveclock's only knob: with this false it does
    # `rightBox.add_child(dateMenu.container)`, appending the clock past
    # everything else; true switches to
    # `insert_child_at_index(…, length - 1)`, which puts it one slot earlier.
    # Read off the extension's own extension.js rather than inferred from the
    # option name, which says only "move the clock before the status menu".
    clock-before-statusmenu = true;
  };

  # ChromaLeon's icon and accent machinery, held off by declaration.
  #
  # Every one of these three icon toggles, not just recolor-folders, makes
  # recolorUtils.js build a synthetic Adwaita-derived "ChromaLeon" theme and
  # point org/gnome/desktop/interface/icon-theme at it, evicting Papirus-Dark
  # outright. That engine cannot work here in any case: it is a
  # find-and-replace over literal Adwaita hex fills, and Papirus-Dark shares
  # none of them and has no scalable/ directory to walk. So the recolour would
  # not merely fail, it would replace a working icon theme with a broken one.
  #
  # gnome-colors is the fourth, and it is a different key space: with it on,
  # ui/wallpaperPage.js writes org/gnome/desktop/interface/accent-color
  # directly, and it fires on merely VIEWING the wallpaper page when the
  # current accent is not among the wallpaper's extracted candidates. That
  # would silently overwrite the accent-color = "red" that
  # nix/home/profiles/portable.nix declares, and nothing in ChromaLeon ever
  # restores it -- disable() only ever puts icon-theme back.
  #
  # Pinned rather than left at the upstream defaults, which are already false,
  # for the reason the notification-position block below gives: a default is
  # the author's choice and can move between releases, this is a requirement.
  # It also self-heals a manual Preferences toggle on the next switch, which
  # matters because that UI writes straight to the gschema and bypasses
  # home-manager entirely.
  dconf.settings."org/gnome/shell/extensions/chromaleon" = {
    recolor-folders = false;
    recolor-apps = false;
    morewaita = false;
    gnome-colors = false;
  };

  dconf.settings."org/gnome/shell/extensions/notification-position" = {
    # Set explicitly even though 'top-right' is currently the schema default.
    # A default is the extension author's choice and can move between
    # releases; this is a requirement, and the whole point of declaring the
    # desktop is that it does not drift when a package is bumped.
    position = "top-right";
  };

  dconf.settings."org/gnome/shell" = {
    enabled-extensions = map (e: e.extensionUuid) extensions;
    # Shell refuses to load anything at all when this is false, which is the
    # state a failed extension update or a Shell version bump can leave behind.
    disable-user-extensions = false;
  };
}
