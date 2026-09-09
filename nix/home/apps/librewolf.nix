# LibreWolf runs natively (programs.librewolf, Home Manager's firefox-module
# wrapper) since the flatpak migration; the module owns ~/.librewolf, writes
# profiles.ini itself and pins the single, always-default "default" profile
# below so LibreWolf never falls back to an auto-generated one. The old
# ~/.var/app/io.gitlab.librewolf-community injection is gone with the flatpak.
#
# Extensions (Bitwarden, SponsorBlock) come Nix-pinned from the
# firefox-addons flake input. The profile ships stock chrome (no
# userChrome/userContent); personal pref deltas live in personalPrefs.
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
  aipageFirefox,
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

  # AIPage (EduPage AI sidebar — codeberg.org/dasmatus/aipage), built inside
  # this flake from a pinned fetchGit source (see nix/packages/aipage.nix +
  # flake.nix packages.aipage-firefox). `aipageFirefox` is the unpacked
  # dist dir (a store path); HM's firefox module installs each
  # extensions.packages entry by symlinking a buildEnv of
  # share/mozilla/extensions/<Firefox-app-GUID>/ into the profile's
  # extensions/ dir, so the package below exposes passthru.addonId and places
  # the XPI at <GUID>/<addonId>.xpi. {ec8030f7-…} is Firefox/LibreWolf's app
  # GUID; the gecko id + version are read from the built manifest at eval
  # time (aipageFirefox.passthru.manifest — pure-eval-safe readFile of a
  # fetchGit store path), so there's no hardcoded version to drift.
  firefoxAppId = "{ec8030f7-c20a-464f-9b0e-13a3a9e97384}";
  aipageManifest = aipageFirefox.passthru.manifest;
  aipageId = aipageManifest.browser_specific_settings.gecko.id;
  aipageVersion = aipageManifest.version;
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

    # Force dark content color-scheme.
    "layout.css.prefers-color-scheme.content-override" = 2;

    # Delay update-available restart prompts.
    "app.update.suppressPrompts" = true;

    # Auto-enable the declaratively installed extensions (otherwise every
    # extensions.packages entry needs a manual "Enable" click on first run).
    "extensions.autoDisableScopes" = 0;
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
  # LibreWolf is a FLATPAK now (io.gitlab.librewolf-community, declared in
  # nix/home/base/flatpaks.nix). `package = null` keeps this module doing the
  # part that matters — rendering the arkenfox user.js, the search engine list
  # and the pinned extension XPIs into the profile — while installing nothing.
  #
  # Everything below is unchanged: the profile is still written to
  # ~/.librewolf. The Flathub manifest runs the browser with
  # `--persist=.librewolf`, so inside the sandbox that name resolves to
  # ~/.var/app/io.gitlab.librewolf-community/.librewolf instead; the symlink
  # at the bottom of this file bridges the two.
  programs.librewolf = {
    enable = true;
    package = null;
    profiles.default = {
      isDefault = true;
      extraConfig = userJs;

      # Default search: DuckDuckGo, through LibreWolf's OWN app-provided
      # engine rather than a hand-written duckduckgo.com URL. `ddg` is the id
      # LibreWolf ships it under, and its record is NOT upstream Firefox's:
      # LibreWolf's search-config-v2.json (browser/omni.ja,
      # defaults/settings/main/) names it "DuckDuckGo No-AI" and points it at
      # https://noai.duckduckgo.com/ with suggestions on ac.duckduckgo.com.
      # Naming the id inherits all of that, plus the icon; spelling out a
      # duckduckgo.com template here would silently opt back INTO the AI
      # results LibreWolf strips. It also puts the browser back on its own
      # shipped default — that same file's defaultEngines record is
      # globalDefault = globalDefaultPrivate = "ddg".
      #
      # Nothing has to be declared under `engines` for that: home-manager
      # infers an id matching no entry there as app-provided
      # (profiles/search.nix, `engineInput`) and emits it with
      # `_isAppProvided = true`.
      #
      # It used to be the local SearXNG instance
      # (nix/modules/services/searxng.nix), which only ever resolves on a host
      # that is actually running it. This module sits in the PORTABLE half of
      # the profile (nix/home/profiles/portable.nix), so it installs on
      # foreign hosts too, where nothing listens on 127.0.0.1:8888 and every
      # address-bar search died with connection-refused. That is the same
      # reason the Brave policy in nix/modules/desktop/desktop.nix names a
      # public provider; this is the browser that had been left behind.
      #
      # SearXNG stays declared but demoted — it is a real engine in the list,
      # reachable on demand through @sx, and simply not what the address bar
      # picks. Unlike Brave's mandatory policy set, a non-default engine that
      # points at a dead port costs nothing until someone types the alias.
      #
      # force is required — LibreWolf rewrites search.json.mozlz4 on every
      # launch, so a non-forced declarative config loses the race after the
      # first start. Engines are keyed by id since HM's search schema v7+;
      # `name` is the display name.
      search = {
        force = true;
        default = "ddg";
        privateDefault = "ddg";
        order = [
          "ddg"
          "searxng"
        ];
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
    };
  };

  # Write the profile straight INTO the flatpak's persisted directory instead
  # of writing it to ~/.librewolf and symlinking.
  #
  # The symlink cannot be made to work, and not for a permissions reason. The
  # Flathub manifest runs the browser with `--persist=.librewolf`, and flatpak
  # REFUSES a symlink at a persist path outright:
  #
  #   F: Failed to create persist path .librewolf:
  #      Symbolic link ".librewolf" not allowed to avoid sandbox escape
  #
  # That guard fires before any Context.filesystems grant is consulted, so no
  # permission fixes it, and `mkOutOfStoreSymlink` has no variant that dodges
  # it — being a symlink is the entire mechanism. The browser did not start at
  # all: this was a hard failure, not a profile that came up empty.
  #
  # `configPath` is a real option on home-manager's mkFirefoxModule
  # (modules/programs/firefox/mkFirefoxModule.nix), defaulting to
  # `platforms.linux.configPath` = ".librewolf". Pointing it here makes the
  # module emit profiles.ini, user.js, search.json.mozlz4 and the extensions/
  # XPIs at the path flatpak already owns, so no symlink is involved. Inside
  # the sandbox that directory IS ~/.librewolf, so nothing changes from the
  # browser's point of view.
  #
  # The writability concern the previous comment raised does not apply:
  # home-manager only symlinks the specific files it generates. The profile
  # DIRECTORY is a real directory, so the session store, extension state and
  # everything else LibreWolf rewrites are ordinary writable files beside
  # them. What those per-file store symlinks do need is a sandbox that can
  # read /nix/store — see the grant in nix/home/base/flatpaks.nix, which is
  # required for this reason and not for the one its own comment gives.
  programs.librewolf.configPath = ".var/app/io.gitlab.librewolf-community/.librewolf";
}
