# AppArmor — the part that actually attaches to anything. Split out of
# nix/modules/system/hardening.nix because the profiles below are already the
# bulk of it and will grow as each one is flipped to enforce.
#
# hardening.nix still loads every profile from pkgs.apparmor-profiles, and that
# load confines nothing. Measured 2026-09-05: `aa-enabled` answered Yes,
# /sys/kernel/security/apparmor/profiles held 223 entries, and reading
# /proc/[0-9]*/attr/current across the whole machine returned `unconfined` for
# every single process. Those are upstream FHS profiles attaching to paths like
# /usr/bin/brave, and /usr/bin here contains exactly one file, `env`. A profile
# that matches no executable is not protection, and on the Security page it is
# worse than none, because 223 reads as a healthy number. Read that count as
# "loaded", never as "confined".
#
# This file is the narrow answer to that: five profiles aimed at real store
# binaries. nix/modules/system/apparmor-store.nix is the wide one — a
# complain-mode catch-all over the whole store whose denial log feeds
# `dots-sandbox triage`, which is how the rules for the apps not covered here
# get written. The catch-all attaches to /nix/store/*/** and therefore also
# matches the five binaries below; AppArmor picks the most specific attachment,
# so these profiles still win for their own executables.
#
# Three details decide whether these five actually attach:
#
#  1. $out/bin/<name> is the wrong path. Every one of these packages ships a
#     makeWrapper shell script there, and claude-desktop ships a makeCWrapper
#     ELF. AppArmor attaches to the binary the kernel finally execs, so a
#     profile on $out/bin/brave matches nothing and says nothing about it. The
#     paths below came from following each wrapper down to its ELF.
#  2. The attachments are globs rather than "${pkgs.foo}" interpolations.
#     home-manager wraps some of these: zed arrives as zed-editor-wrapped-1.14.2,
#     a different store path than pkgs.zed-editor, so interpolating the
#     system-side package would aim the profile at a binary nobody runs. A glob
#     matches whichever store path actually executes, across rebuilds.
#  3. Everything here is state = "complain". These profiles log and permit; they
#     block nothing yet. Flipping one to "enforce" is a separate change that
#     needs evidence: run the app, read its ALLOWED lines out of the audit log,
#     fold the real accesses into the rules, then switch that one profile.
{
  pkgs,
  lib,
  ...
}:
let
  # Shared by every profile below. Kept in one place because five copies would
  # drift apart within a month.
  common = ''
    include <abstractions/base>
    include <abstractions/nameservice>
    include <abstractions/fonts>
    include <abstractions/freedesktop.org>
    include <abstractions/dbus-session-strict>
    include <abstractions/audio>
    include <abstractions/wayland>
    include <abstractions/mesa>
    include <abstractions/opengl>
    include <abstractions/p11-kit>
    include <abstractions/ssl_certs>
    include <abstractions/user-tmp>

    # The store holds the program's own code and data and is read-only anyway,
    # so read and mmap are safe to grant wholesale. `ix` keeps helper binaries
    # (crashpad handlers, zygotes, ffmpeg) inside this same profile instead of
    # escaping to unconfined.
    /nix/store/** rm,
    /nix/store/**/bin/* ix,
    /nix/store/**/libexec/** ix,

    # Chromium, Electron and Firefox all build their renderer sandbox out of
    # user namespaces. Without this the zygote dies and the app comes up broken
    # or not at all. This is the rule most likely to matter at the enforce flip.
    userns,

    network inet stream,
    network inet6 stream,
    network inet dgram,
    network inet6 dgram,
    network netlink raw,
    network unix stream,
    network unix dgram,

    owner @{HOME}/** rwkl,
    owner /tmp/** rwkl,
    @{run}/user/@{uid}/** rwkl,
    @{PROC}/@{pid}/** r,
    /sys/devices/** r,
    /dev/dri/* rw,
    /dev/shm/** rwk,

    # The whole point. A browser, an editor and a chat client each have a
    # plausible reason to read $HOME and no reason at all to touch the signing
    # and login material sitting in it. `deny` beats the owner rule above
    # regardless of ordering, and silences the log for these paths too.
    deny @{HOME}/.ssh/** mrwklx,
    deny @{HOME}/.gnupg/** mrwklx,

    # rbw is the Bitwarden client (nix/home/apps/bitwarden.nix): the vault cache
    # lives under .local/share/rbw and its agent socket owns SSH_AUTH_SOCK for
    # the whole session. Reaching that socket is enough to authenticate and sign
    # as the user without ever touching a key file, so it is denied by path.
    deny @{HOME}/.local/share/rbw/** mrwklx,
    deny @{HOME}/.config/rbw/** mrwklx,
    deny @{run}/user/@{uid}/rbw/** mrwklx,

    # The dots sandbox broker's own state and audit log.
    deny @{HOME}/.local/share/dots-sandbox/** mrwklx,
  '';

  # `profile <name> <attachment>` keeps the in-profile name equal to the policy
  # attribute name, which is what the NixOS module compares against when it
  # unloads profiles that are no longer declared.
  #
  # There is deliberately no per-app rule hook here. The first attempt gave zed
  # its own `/nix/store/**/bin/* Ux,` for language servers, and apparmor_parser
  # rejected it outright: "has merged rule /nix/store/**/bin/* with conflicting
  # x modifiers", because `common` already grants `ix` on that same glob. `ix`
  # is the stricter of the two anyway, since it runs helpers inside this profile
  # instead of letting them out unconfined, so nothing needed the override.
  mkProfile = name: attachment: ''
    abi <abi/4.0>,

    include <tunables/global>

    profile ${name} ${attachment} flags=(attach_disconnected,mediate_deleted) {
      ${common}
    }
  '';

  # Attachment paths resolved by following each package's wrapper to the ELF:
  #   brave          bin/brave (sh) -> .brave-wrapped -> opt/brave.com/brave/
  #                  brave-browser (sh) -> opt/brave.com/brave/brave
  #   librewolf      bin/librewolf (sh) -> .librewolf-wrapped -> lib/librewolf/
  #                  librewolf
  #   claude-desktop bin/claude-desktop (makeCWrapper ELF) -> lib/claude-desktop/
  #                  claude-desktop
  #   zed            bin/zeditor (sh) -> .zeditor-wrapped -> libexec/zed-editor
  apps = {
    dots-brave = "/nix/store/*/opt/brave.com/brave/brave";
    dots-librewolf = "/nix/store/*/lib/librewolf/librewolf";
    dots-claude-desktop = "/nix/store/*/lib/claude-desktop/claude-desktop";
    # Zed reaches language servers, formatters and git through the `ix` rule in
    # `common`, which runs them under this same profile.
    dots-zed = "/nix/store/*/libexec/zed-editor";
    # Obsidian is the one app here with no binary of its own. Its wrapper execs
    # the shared electron with an app.asar path, so there is no Obsidian-only
    # file to attach to, and this profile therefore covers every Electron app
    # running that binary rather than Obsidian specifically. Named for what it
    # actually is instead of pretending otherwise.
    dots-electron = "/nix/store/*/bin/electron";
  };
in
{
  security.apparmor = {
    enable = true;

    # NOT dead code, and not the thing that loads the stock profiles. In
    # nixpkgs' own words this is "List of packages to be added to AppArmor's
    # include path": it is what makes `include <abstractions/base>` and
    # `include <tunables/global>` above resolve. Drop it and every profile here
    # fails to parse, which fails the unit, which fails the switch.
    packages = [ pkgs.apparmor-profiles ];

    policies = lib.mapAttrs (name: attachment: {
      state = "complain";
      profile = mkProfile name attachment;
    }) apps;
  };

  # Upstream default is true, which kills any process that has a profile but is
  # running unconfined when profiles load. That would shoot down every browser
  # and editor already open the moment a rebuild switches. Complain mode gains
  # nothing from it either, since it blocks nothing to begin with. Revisit when
  # the first profile goes to enforce.
  security.apparmor.killUnconfinedConfinables = false;
}
