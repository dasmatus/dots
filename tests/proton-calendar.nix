# Regression guard for the Proton calendar's arrival in the mail client.
# Eval-only, in the style of tests/session-units.nix: no VM, no activation,
# just a standalone `home-manager.lib.homeManagerConfiguration` read back
# through `.config` and checked with asserts. Same reason as that file for not
# using `nixosConfigurations.tokyonight`: nix/data/settings.nix and nix/data/facter.json
# are symlinks into /var/lib/dots and facter.json is mode 0600 root-owned, so
# anything routed through nix/system/hosts.nix dies on permissions whatever
# `--impure` is passed.
#
# What this exists to catch is the profile path. nix/home/proton/proton.nix runs
# Betterbird rather than Thunderbird (for its tray icon), and the calendar in
# nix/home/proton/proton-calendar.nix is delivered as prefs written into the mail
# client's profile. Those two facts are only compatible because
# home-manager's thunderbird module hardcodes
# `thunderbirdConfigPath = if isDarwin then "Library/Thunderbird" else ".thunderbird"`,
# a constant with no reference to `cfg.package`. The day that becomes
# package-derived, Betterbird's profile moves to ~/.betterbird, every pref
# below keeps being generated into ~/.thunderbird, and the calendar silently
# stops appearing with nothing failing anywhere. Hence an assert on the path
# rather than only on the contents.
{
  pkgs,
  lib,
  inputs,
}:
let
  hm = inputs.home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    # nix/home/proton/proton.nix reads exactly these two, for the mail account's
    # address and display name. Fake values: what matters here is that the
    # module takes them from `dots` at all rather than from a literal.
    extraSpecialArgs = {
      dots = {
        gitEmail = "ada@example.com";
        gitName = "Ada Lovelace";
      };
      # nix/home/proton/proton.nix takes the mail client as a module argument rather
      # than off pkgs, because nixpkgs has no betterbird and this repo keeps
      # its own packages out of an overlay (flake/nixos.nix threads them
      # through specialArgs instead). Built here the same way flake/packages.nix
      # builds it, so this test exercises the real derivation.
      betterbird = pkgs.callPackage ../nix/packages/betterbird.nix { };
    };
    modules = [
      {
        home.username = "proton-calendar-test";
        home.homeDirectory = "/home/proton-calendar-test";
        home.stateVersion = "26.05";
        # proton.nix puts pkgs.proton-vpn in home.packages. Nothing asserted
        # below forces that list, but the predicate is spelled out so a
        # licence change upstream cannot turn this test red for a reason that
        # has nothing to do with calendars.
        nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "proton-vpn" ];
      }
      ../nix/home/proton/proton.nix
      ../nix/home/proton/proton-calendar.nix
    ];
  };
  cfg = hm.config;

  # --- 1. The profile is still the one Betterbird opens. --------------------
  profilePath = ".thunderbird/default/user.js";
  generatedPaths = builtins.attrNames cfg.home.file;
  profileFiles = builtins.filter (p: lib.hasSuffix "/user.js" p) generatedPaths;
  profileFilesMsg = lib.concatStringsSep ", " profileFiles;
  profileAtExpectedPath = builtins.any (p: lib.hasSuffix profilePath p) generatedPaths;

  # Read the generated prefs back as text. home-manager renders user.js from
  # `profile.settings`, so this is the literal file the client will parse.
  userJs =
    let
      match = builtins.filter (p: lib.hasSuffix profilePath p) generatedPaths;
    in
    if match == [ ] then "" else cfg.home.file.${builtins.head match}.text;

  # --- 2. The calendar points at the file the exporter writes. -------------
  # Asserting the URI, not merely that some calendar exists: a registry entry
  # aimed at a path nothing generates is the failure this pairing invites.
  icsPath = "${cfg.xdg.stateHome}/proton-calendar/proton.ics";
  hasCalendarUri = lib.hasInfix ''"file://${icsPath}"'' userJs;

  # --- 3. The calendar is registered read-only. -----------------------------
  # Proton exposes no CalDAV, so edits made in the client cannot reach the
  # account and are silently dropped by the next export. Without readOnly the
  # client offers an edit dialog that looks like it works, which reads as data
  # loss to whoever tries it.
  hasReadOnly = lib.hasInfix "readOnly" userJs && lib.hasInfix "calendar.registry" userJs;

  # --- 4. Something actually writes that file. ------------------------------
  hasExporterService = cfg.systemd.user.services ? "proton-calendar-export";
  hasExporterTimer = cfg.systemd.user.timers ? "proton-calendar-export";

  # --- 5. The mail account carries no literal address. ----------------------
  # The whole point of routing identity through `dots`: this repo is public.
  account = cfg.accounts.email.accounts.proton;
  addressFromDots = account.address == "ada@example.com" && account.realName == "Ada Lovelace";
in
assert lib.assertMsg profileAtExpectedPath ''
  tests/proton-calendar.nix: no generated profile at ${profilePath}.
  Generated user.js path(s): ${if profileFiles == [ ] then "(none)" else profileFilesMsg}.
  home-manager's thunderbird module used to hardcode ".thunderbird" regardless
  of `package`; if it now derives the directory from the package, Betterbird's
  profile has moved and nix/home/proton/proton-calendar.nix writes its calendar prefs
  somewhere the client never reads.'';
assert lib.assertMsg hasCalendarUri ''
  tests/proton-calendar.nix: the generated user.js has no calendar registered
  at file://${icsPath}, which is the path nix/home/proton/proton-calendar.nix's
  exporter writes. A registry entry and an exporter that disagree about the
  filename leave an empty calendar and no error anywhere.'';
assert lib.assertMsg hasReadOnly ''
  tests/proton-calendar.nix: the Proton calendar is not registered read-only.
  Proton has no CalDAV, so an edit made in the client reaches nothing and is
  overwritten by the next export. Read-only is what stops the client offering
  an edit dialog that silently discards the result.'';
assert lib.assertMsg (hasExporterService && hasExporterTimer) ''
  tests/proton-calendar.nix: proton-calendar-export is missing its ${
    if hasExporterService then "timer" else "service"
  }.
  The registered calendar is a plain file; with nothing on a schedule to
  rewrite it, it is a snapshot that ages silently rather than a calendar.'';
assert lib.assertMsg addressFromDots ''
  tests/proton-calendar.nix: accounts.email.accounts.proton does not take its
  address and realName from `dots`. This repo is public, and an address
  written into nix/home/proton/proton.nix as a literal is in the clone history for
  good.'';
pkgs.writeText "proton-calendar-ok" ''
  profile-path-unmoved
  calendar-uri-matches-exporter
  calendar-read-only
  exporter-scheduled
  identity-from-dots
''
