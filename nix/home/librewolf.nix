# LibreWolf runs natively (programs.librewolf, Home Manager's firefox-module
# wrapper) since the flatpak migration; the module owns ~/.librewolf, writes
# profiles.ini itself and pins the single, always-default "default" profile
# below so LibreWolf never falls back to an auto-generated one. The old
# ~/.var/app/io.gitlab.librewolf-community injection is gone with the flatpak.
#
# Extensions (Bitwarden, SponsorBlock) come Nix-pinned from the
# firefox-addons flake input; the chrome is rafaelmardojai's
# firefox-gnome-theme (nixpkgs) @imported from the store, with its required
# prefs asserted in personalPrefs below.
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
{
  config,
  pkgs,
  inputs,
  ...
}:
let
  # Pin: https://github.com/arkenfox/user.js/releases — latest as of writing.
  arkenfoxJs = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/arkenfox/user.js/144.0/user.js";
    hash = "sha256-5KszxpFImRdc9wNeDlei1/CKyIfY+VfxGZ5+Sbvn4z4=";
  };

  # Nix-pinned XPIs from the firefox-addons flake input (rycee's subflake,
  # not the whole NUR); installed into the profile as a buildEnv symlink.
  addons = inputs.firefox-addons.packages.${pkgs.stdenv.hostPlatform.system};

  # AIPage (EduPage AI sidebar — codeberg.org/dasmatus/aipage), built from
  # source in the sibling aipage repo. The gitignored dist-firefox dir can't
  # be a flake input (path inputs outside this flake aren't store-copied), so
  # a deterministic tarball of it lives at
  # ~/.local/share/aipage/dist-firefox.tar and is pulled in here as an
  # eval-time fixed-output derivation (builtins.fetchTarball fetches outside
  # the build sandbox, so sandbox=true is fine). HM's firefox module installs
  # each extensions.packages entry by symlinking a buildEnv of
  # share/mozilla/extensions/<Firefox-app-GUID>/ into the profile's
  # extensions/ dir, so the package must expose passthru.addonId and place
  # the XPI at <GUID>/<addonId>.xpi. {ec8030f7-…} is Firefox/LibreWolf's app
  # GUID; the gecko id + version come from the built manifest — hardcoded
  # here (pure-eval `nix flake check` can't readFile a path input). Bump the
  # sha256 + version when aipage is rebuilt (see scripts/update-aipage.sh).
  aipageFirefox = builtins.fetchTarball {
    url = "file://${config.home.homeDirectory}/.local/share/aipage/dist-firefox.tar";
    sha256 = "0ygv4w01p5a2rqspmry26ncyf0h77v1x69va8vv3cz14izc1ssh1";
  };
  firefoxAppId = "{ec8030f7-c20a-464f-9b0e-13a3a9e97384}";
  aipageId = "edupage-ai-sidebar@hesburger.dev";
  aipageVersion = "1.7.0";
  aipageXpi =
    pkgs.runCommand "aipage-${aipageVersion}"
      {
        passthru.addonId = aipageId;
      }
      ''
        extDir="$out/share/mozilla/extensions/${firefoxAppId}"
        mkdir -p "$extDir"
        ( cd "${aipageFirefox}" && ${pkgs.lib.getExe pkgs.zip} -rX "$extDir/${aipageId}.xpi" . )
      '';

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
  programs.librewolf = {
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
        aipageXpi
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
