# LibreWolf runs as a flatpak (io.gitlab.librewolf-community). Flatpak's
# `--persist=.librewolf` redirects the app's $HOME/.librewolf into
# ~/.var/app/io.gitlab.librewolf-community/.librewolf/, so that's where a
# profile has to be injected for home-manager to manage it declaratively.
# profiles.ini below pins a single, always-default "default" profile so
# LibreWolf never falls back to its own auto-generated one.
#
# LibreWolf itself already ships an arkenfox-derived set of hardened
# defaults baked into the browser (see LibreWolf's own defaults/pref
# overrides upstream) — those still apply underneath. The user.js written
# here stacks on top of that: first the upstream arkenfox base verbatim,
# then this repo's personal overrides last (so they win on any conflict).
#
# History: the repo used to ship a hand-maintained user.js at the repo
# root — stock arkenfox v115 (115.1, 27 August 2023) plus a personal
# "// My stuff" section appended at the end, plus one inline value flip
# (4504 letterboxing) in the middle of the arkenfox block. That file was
# retired in favour of this module; arkenfox is now fetched fresh (so it
# tracks current Firefox/LibreWolf versions) and the personal deltas were
# ported forward into `personalPrefs` below.
#
# Delta audit against arkenfox 144.0 (current pin, see `arkenfoxJs`): none
# of the ported prefs are renamed/removed in the new base.
#   - privacy.resistFingerprinting.letterboxing: v115 arkenfox set this
#     `true` by default (4504) and the old user.js flipped it to `false`.
#     In 144.0 arkenfox no longer sets 4504 by default (left commented,
#     i.e. Firefox default applies) — the pref itself is unchanged/still
#     valid, so the explicit `false` override below still does exactly
#     what it did before.
#   - browser.download.alwaysOpenPanel / .manager.addToRecentDocs /
#     always_ask_before_handling_new_types: present verbatim in 144.0
#     arkenfox (2652/2653/2654) with the same values the old user.js
#     re-asserted — kept for explicitness even though redundant.
#   - Everything else in `personalPrefs` (smooth scroll physics, bookmark
#     UI tweaks, pdfjs/newtab/pocket toggles, etc.) was never part of
#     arkenfox to begin with, so there's nothing upstream to go stale.
{ pkgs, ... }:
let
  # Pin: https://github.com/arkenfox/user.js/releases — latest as of writing.
  arkenfoxJs = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/arkenfox/user.js/144.0/user.js";
    hash = "sha256-5KszxpFImRdc9wNeDlei1/CKyIfY+VfxGZ5+Sbvn4z4=";
  };

  # Personal deltas carried over from the retired repo-root user.js
  # (arkenfox v115.1 base + "// My stuff" section), diffed pref-by-pref
  # against arkenfox 115.1 and re-applied here so they win over both
  # LibreWolf's built-in defaults and the fetched arkenfox base.
  personalPrefs = {
    # 4504 override: arkenfox default is `true`; keep letterboxing off.
    "privacy.resistFingerprinting.letterboxing" = false;

    # Smooth scrolling / mouse wheel physics tuning.
    "apz.overscroll.enabled" = true; # not DEFAULT on Linux
    "general.smoothScroll" = true; # DEFAULT
    "general.smoothScroll.msdPhysics.continuousMotionMaxDeltaMS" = 12;
    "general.smoothScroll.msdPhysics.enabled" = true;
    "general.smoothScroll.msdPhysics.motionBeginSpringConstant" = 600;
    "general.smoothScroll.msdPhysics.regularSpringConstant" = 650;
    "general.smoothScroll.msdPhysics.slowdownMinDeltaMS" = 25;
    "general.smoothScroll.msdPhysics.slowdownMinDeltaRatio" = 2.0;
    "general.smoothScroll.msdPhysics.slowdownSpringConstant" = 250;
    "general.smoothScroll.currentVelocityWeighting" = 1.0;
    "general.smoothScroll.stopDecelerationWeighting" = 1.0;
    "mousewheel.default.delta_multiplier_y" = 300;

    # Bookmarks / UI convenience.
    "browser.tabs.loadBookmarksInTabs" = true; # open bookmarks in a new tab
    "browser.bookmarks.openInTabClosesMenu" = false; # keep bookmarks menu open
    "browser.menu.showViewImageInfo" = true; # restore "View image info"
    "findbar.highlightAll" = true; # show all matches in findbar
    "pdfjs.sidebarViewOnLoad" = 2;
    "browser.compactmode.show" = true; # add compact mode back to options

    # Downloads (redundant with arkenfox 2652-2654 but asserted explicitly).
    "browser.download.always_ask_before_handling_new_types" = true;
    "browser.download.alwaysOpenPanel" = false;
    "browser.download.manager.addToRecentDocs" = false;

    # Disable Pocket / sponsored & recommended newtab content.
    "extensions.pocket.enabled" = false;
    "browser.newtabpage.activity-stream.feeds.topsites" = false;
    "browser.newtabpage.activity-stream.feeds.section.topstories" = false;

    # Force dark content color-scheme, allow userChrome/userContent.
    "layout.css.prefers-color-scheme.content-override" = 2;
    "toolkit.legacyUserProfileCustomizations.stylesheets" = true;

    # Delay update-available restart prompts.
    "app.update.suppressPrompts" = true;
  };

  renderPref = name: value: "user_pref(${builtins.toJSON name}, ${builtins.toJSON value});";

  personalPrefsText = builtins.concatStringsSep "\n" (
    map (name: renderPref name personalPrefs.${name}) (builtins.attrNames personalPrefs)
  );

  userJs =
    builtins.readFile arkenfoxJs
    + "\n\n// personal overrides (from the retired repo user.js)\n"
    + personalPrefsText
    + "\n";
in
{
  home.file = {
    ".var/app/io.gitlab.librewolf-community/.librewolf/profiles.ini".text = ''
      [Profile0]
      Name=default
      IsRelative=1
      Path=default
      Default=1

      [General]
      StartWithLastProfile=1
      Version=2
    '';

    ".var/app/io.gitlab.librewolf-community/.librewolf/default/user.js".text = userJs;
  };
}
