{ pkgs, inputs, ... }:
let
  # Pin: https://github.com/arkenfox/user.js/releases — latest as of writing.
  arkenfoxJs = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/arkenfox/user.js/144.0/user.js";
    hash = "sha256-5KszxpFImRdc9wNeDlei1/CKyIfY+VfxGZ5+Sbvn4z4=";
  };

  # Nix-pinned XPIs from the firefox-addons flake input (rycee's subflake,
  # not the whole NUR); installed into the profile as a buildEnv symlink.
  addons = inputs.firefox-addons.packages.${pkgs.stdenv.hostPlatform.system};

  # rafaelmardojai/firefox-gnome-theme, imported straight from the store via
  # userChrome/userContent below. Its nested @imports resolve relative to the
  # importing sheet, so the single absolute file:// import is enough.
  gnomeTheme = pkgs.firefox-gnome-theme;

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

    # Auto-enable the declaratively installed extensions (otherwise every
    # extensions.packages entry needs a manual "Enable" click on first run).
    "extensions.autoDisableScopes" = 0;

    # firefox-gnome-theme required prefs (its configuration/user.js, minus
    # legacyUserProfileCustomizations.stylesheets which is already set above;
    # svg.context-properties is required or the theme icons render black).
    "svg.context-properties.content.enabled" = true;
    "browser.uidensity" = 0;
    "browser.theme.dark-private-windows" = false;
    "widget.gtk.rounded-bottom-corners.enabled" = true;
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
  programs.firefox = {
    enable = true;
    profiles.default = {
      isDefault = true;
      extraConfig = userJs;

      # Default search: the local SearXNG instance (nix/modules/searxng.nix).
      # force is required — LibreWolf rewrites search.json.mozlz4 on every
      # launch, so a non-forced declarative config loses the race after the
      # first start. Engines are keyed by id since HM's search schema v7+;
      # `name` is the display name.
      search = {
        force = true;
        default = "searxng";
        privateDefault = "searxng";
        order = [ "searxng" ];
        engines.searxng = {
          name = "SearXNG";
          urls = [ { template = "http://127.0.0.1:8888/search?q={searchTerms}"; } ];
          definedAliases = [ "@sx" ];
        };
      };

      # NB: setting extensions.packages makes the module own the profile's
      # extensions/ dir — manually installed addons get replaced on switch.
      extensions.packages = [
        addons.bitwarden
        addons.sponsorblock
      ];

      userChrome = ''
        @import "file://${gnomeTheme}/share/firefox-gnome-theme/userChrome.css";
      '';
      userContent = ''
        @import "file://${gnomeTheme}/share/firefox-gnome-theme/userContent.css";
      '';
    };
  };
}
