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
# This file is the narrow answer to that: profiles aimed at real store
# binaries. nix/modules/system/apparmor-store.nix is the wide one — a
# complain-mode catch-all over the whole store whose denial log feeds
# `dots-secreport triage`, which is how the rules below were derived (see
# each profile's own state for which ones that has actually happened for).
# The catch-all attaches to /nix/store/*/** and therefore also matches every
# binary below; AppArmor picks the most specific attachment, so these
# profiles still win for their own executables.
#
# Three details decide whether these actually attach:
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
#  3. `state` is per-app, not file-wide any more (Phase E). `claude-desktop`
#     moved to "enforce" — it has no Flathub package (see
#     nix/home/base/flatpaks.nix's header) and every other GUI app on this
#     machine is a Flatpak now, so it is one of the two remaining native
#     holdouts with no sandbox of its own. `brave`, `librewolf`, `zed` and
#     `electron` (Obsidian) stay "complain": every app they cover is a
#     Flatpak today (nix/home/base/flatpaks.nix), so these four profiles are
#     now largely vestigial — kept rather than deleted because nothing
#     proves they attach to nothing (a home-manager package override could
#     still route a binary through one of these paths), and deleting a
#     profile that turns out to still matter is a harder mistake to notice
#     than leaving an inert one in complain mode. Revisit once it is certain
#     nothing still execs through them.
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
  #   haveno         bin/haveno (bwrap wrapper script, see its own state note)
  #
  # `state` moved in per-app (Phase E): `dots-sandbox triage`'s successor,
  # `dots-secreport triage`, is what derives it from the store-catchall's
  # complain-mode denial log rather than a hand guess — see each app's own
  # comment for what that run found.
  apps = {
    dots-brave = {
      attach = "/nix/store/*/opt/brave.com/brave/brave";
      state = "complain";
    };
    dots-librewolf = {
      attach = "/nix/store/*/lib/librewolf/librewolf";
      state = "complain";
    };
    # Moved to enforce: claude-desktop has no Flathub package
    # (nix/home/base/flatpaks.nix's header — com.anthropic.Claude 404s), so
    # it is one of only two native GUI holdouts left with no Flatpak
    # sandbox of its own. It is a plain Electron binary at a stable resolved
    # path, the same shape `common` above was already written for, and a
    # `dots-secreport triage --input` run over a captured complain-mode
    # denial log for this exact profile found nothing `common`'s existing
    # rules do not already cover (userns for the sandboxed renderer, the
    # network/wayland/dbus/audio abstractions, owner @{HOME}/** for its own
    # config and cache) — no denial needed folding in before this flip.
    dots-claude-desktop = {
      attach = "/nix/store/*/lib/claude-desktop/claude-desktop";
      state = "enforce";
    };
    # Zed reaches language servers, formatters and git through the `ix` rule in
    # `common`, which runs them under this same profile.
    dots-zed = {
      attach = "/nix/store/*/libexec/zed-editor";
      state = "complain";
    };
    # Obsidian is the one app here with no binary of its own. Its wrapper execs
    # the shared electron with an app.asar path, so there is no Obsidian-only
    # file to attach to, and this profile therefore covers every Electron app
    # running that binary rather than Obsidian specifically. Named for what it
    # actually is instead of pretending otherwise.
    dots-electron = {
      attach = "/nix/store/*/bin/electron";
      state = "complain";
    };
    # Haveno (nix/home/base/pkgs.nix, appimageTools.wrapType2) is the OTHER
    # native GUI holdout with no Flathub package
    # (nix/home/base/flatpaks.nix's header — exchange.haveno.Haveno 404s).
    # Stays "complain", not "enforce", on real evidence rather than a guess:
    # `bin/haveno` is a bubblewrap wrapper that unshares a NEW mount
    # namespace and re-execs its actual JavaFX payload from generic FHS
    # paths (`/usr/bin/...`) inside that namespace, not from a stable
    # `/nix/store/**` path — AppArmor mediates by the path resolved in the
    # CURRENT mount namespace at exec time (see
    # nix/modules/system/apparmor-store.nix's own header on exactly this),
    # so a profile aimed at the wrapper script's store path cannot see, and
    # therefore cannot authorize, the exec chain bwrap performs after it
    # unshares. A `dots-secreport triage --input` run over a captured
    # complain-mode log confirmed the exec chain crosses that boundary; this
    # is the identical structural shape steam.nix's own profile is in, and
    # the same reason Part 3b of this phase gives for never attempting
    # enforce on Steam. Enforcing this profile as it stands would deny the
    # exec this app depends on to start at all — the `mediate_deleted`
    # rename() trap incident (`9b069e8`, hardening.nix) is the standing
    # reminder of what an untested enforce flip on a namespacing-heavy
    # binary costs.
    dots-haveno = {
      attach = "/nix/store/*/bin/haveno";
      state = "complain";
    };
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

    policies = lib.mapAttrs (name: app: {
      inherit (app) state;
      profile = mkProfile name app.attach;
    }) apps;
  };

  # Upstream default is true, which kills any process that has a profile but is
  # running unconfined when profiles load. That would shoot down every browser
  # and editor already open the moment a rebuild switches. Complain mode gains
  # nothing from it either, since it blocks nothing to begin with. Revisit when
  # the first profile goes to enforce.
  security.apparmor.killUnconfinedConfinables = false;
}
