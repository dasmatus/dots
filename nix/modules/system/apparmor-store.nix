# Store-path AppArmor confinement — the piece hardening.nix's comment on
# `security.apparmor.packages` refers to as "a separate piece of work".
#
# Why this file exists at all: AppArmor attaches a profile to a process by
# matching the executable's resolved path, at exec time, against the
# profile's attachment specifier (apparmor.d(5), "Profile Names and
# Attachment specifications"). Every profile in pkgs.apparmor-profiles is
# written against FHS paths (/usr/bin/foo, /usr/sbin/bar). On NixOS the
# resolved exec path of anything is always /nix/store/<hash>-<name>/...,
# never an FHS path, so none of those ~200 stock profiles ever attach to a
# real process here — that was the finding hardening.nix already documents
# (loaded profiles, zero effective confinement) and confirmed again by
# research-apparmor.md's search of `apparmor-profiles` for anything
# NixOS-shaped. `tunables/alias` (upstream, loaded via includes.nix) does not
# fix this either: alias rewriting is a parser-time text substitution of the
# rule path, done before the kernel resolves the exec'd file, so it maps
# /usr/bin/foo to the /run/current-system/sw/bin/foo *symlink* — but the
# kernel resolves that symlink to the real /nix/store/<hash>-foo/bin/foo
# during execve(2) before AppArmor's LSM hook ever runs, and attachment
# matching happens against that already-resolved store path, not the
# symlink. A profile that only knows about the symlink's path still never
# attaches.
#
# The only way to get a profile that actually attaches on NixOS is to put
# the real store path in the profile text — which means the profile has to
# come from a Nix expression, not a static file, because the path's hash is
# only known once `pkgs.foo` is evaluated and changes on every rebuild that
# touches `foo` or anything in its build closure. `mkStoreProfile` below
# exists for exactly that: interpolate `"${pkgs.foo}/bin/foo"` into the
# profile's attachment specifier and body, and the profile text — therefore
# what `apparmor_parser` (re)loads on the next `nixos-rebuild switch` —
# regenerates automatically whenever that path changes. There is no way to
# get this property from a profile shipped as a plain file.
#
# The successor this file anticipates already exists, and it did not arrive
# through `mkStoreProfile`: nix/modules/system/apparmor.nix hand-writes five
# profiles aimed at the resolved ELF of brave, librewolf, claude-desktop, zed
# and electron. It landed on the other side of the merge that brought this file
# in, which is why the two were designed without knowledge of each other. They
# coexist rather than compete: AppArmor attaches the most specific match, so
# those five binaries run under their own profile and everything else in the
# store falls through to the catch-all below. `mkStoreProfile` stays because it
# is still the right shape for the next profile that wants a package path
# interpolated rather than globbed — apparmor.nix deliberately globs instead,
# since home-manager rewraps some of those packages under a different store
# path than the system-side `pkgs.foo`.
{ pkgs, lib, ... }:
let
  # Reusable generator: given a name, an attachment path (or glob) and a
  # rules body, produces AppArmor profile *text* ready to hand to
  # `security.apparmor.policies.<name>.profile`.
  #
  # `attach` is deliberately just a string, not restricted to
  # `${pkgs.foo}/bin/foo` — callers can pass an exact package output path
  # for a real per-binary profile (the intended future use: one profile per
  # security-sensitive package, generated the same way this file's own
  # catch-all is), or a glob like "/nix/store/*/**" for something that has
  # to match many/unknown store paths (this file's catch-all, below). The
  # quoting around `${attach}` matters once real package paths are used:
  # store paths themselves never contain spaces, but quoting is what lets
  # this same function also accept multi-word `flags=(...)` combinations
  # and keeps the header parse-stable if that ever changes.
  #
  # `attach_disconnected` is included unconditionally: without it, any file
  # descriptor inherited across a mount-namespace boundary (bind mounts,
  # bubblewrap, the Nix build sandbox) resolves to a "disconnected path"
  # that AppArmor cannot match against `attach` at all, and the access is
  # denied outright rather than falling through to a rule. On a system that
  # already runs bwrap-based sandboxing (nix-daemon's builds, this repo's
  # own rust/dots-sandbox), leaving this off is not a hardening choice, it
  # is a guaranteed-breakage footgun — see research-apparmor.md §4 on user
  # namespaces for the exact mechanism.
  mkStoreProfile =
    {
      name,
      attach,
      rules ? "",
      extraFlags ? [ ],
    }:
    let
      flags = [ "attach_disconnected" ] ++ extraFlags;
    in
    ''
      #include <tunables/global>

      profile ${name} "${attach}" flags=(${lib.concatStringsSep "," flags}) {
        #include <abstractions/base>

        ${rules}
      }
    '';
in
{
  security.apparmor.policies."store-catchall" = {
    # MUST stay "complain" until this project has real per-package profiles
    # (via mkStoreProfile above) and has watched their denial logs long
    # enough to trust them. Read this literally, not as a formality:
    #
    #   - Complain mode logs denials. It does not block them. Per
    #     apparmor(7): "complain mode does not provide any security, only
    #     auditing, while it is enabled. It should not be used in a hostile
    #     environment." That is upstream's own wording, not a paraphrase.
    #   - A process under this profile shows up as
    #     `store-catchall (complain)` in /proc/<pid>/attr/current, and
    #     aa-status buckets it under "complain", separate from
    #     "unconfined" — so this profile DOES make lynis's/aa-status's
    #     "N processes unconfined" count go down. That is a real change to
    #     what the audit surface reports.
    #   - It is *only* a reporting change. Nothing here restricts what a
    #     confined process can do: the ruleset below is intentionally
    #     thin, so that in complain mode almost every access is a "gap"
    #     (no matching allow rule) and AppArmor's complain-mode behavior
    #     converts every such gap into ALLOWED-and-logged rather than
    #     denied. That is the desired behavior for this landing — it is
    #     how the denial log gets populated with what real store binaries
    #     actually touch, which is the data needed to write real
    #     `mkStoreProfile` rules per binary. It is explicitly NOT
    #     protection. Do not read "223 profiles loaded" or "0 unconfined"
    #     off of this and conclude the machine is confined; that is
    #     exactly the false-positive this repo got burned by once already
    #     (see the comment above `security.apparmor.packages` in
    #     hardening.nix) and this file must not reproduce it under a new
    #     name.
    #   - Flipping this to "enforce" without first writing real
    #     `pix`/`cix`/exact-path rules for the things this box actually
    #     runs (bwrap/userns for the sandbox stack, PipeWire's runtime
    #     socket, the portal/D-Bus surface, Hyprland's IPC socket — none of
    #     which have a stock AppArmor abstraction, all documented in
    #     research-apparmor.md §4) will break them. This is the user's
    #     daily driver; that flip is future, deliberate, per-binary work,
    #     not a follow-up to this commit.
    state = "complain";
    profile = mkStoreProfile {
      name = "store-catchall";
      # Every regular file under any store output, at any nesting depth
      # (`**` is required, not `*`, to cross the `/` after the
      # hash-name component — see research-apparmor.md §1 for the AARE
      # glob semantics and the parser verification behind this).
      attach = "/nix/store/*/**";
      rules = ''
        # ENFORCING, and deliberately permissive on paths.
        #
        # This profile attaches to every process on the machine, PID 1
        # included, because every binary here is a store path. An enforcing
        # catch-all that also tried to restrict paths would be a
        # whole-system allowlist — it would have to enumerate everything
        # every program on the machine legitimately touches, and the first
        # thing it got wrong would take the desktop down. So paths are
        # open, and what this profile enforces is the small set of
        # operations that nothing normal does and that an attacker needs.
        #
        # Path confinement is bubblewrap's job, per-app, driven by the
        # policy — see rust/dots-sandbox/src/argv.rs. These two layers are
        # deliberately different in kind: bwrap decides which files an app
        # can see, AppArmor decides which privileged operations any process
        # may perform. Neither substitutes for the other, and stacking a
        # per-app path allowlist here would duplicate the first badly.
        /** rwlkm,
        /nix/store/*/** ix,

        # Ordinary operation. Denying any of these breaks the desktop
        # within seconds, and none of them is what an exploit reaches for.
        network,
        unix,
        signal,
        dbus,
        ptrace peer=@{profile_name},

        # Mount is ALLOWED, and that is not an oversight. bubblewrap builds
        # every sandbox out of mount and pivot_root inside a user
        # namespace; denying it here would break the confinement layer that
        # actually restricts paths, trading the strong mechanism for the
        # weak one. The kernel already constrains what an unprivileged user
        # namespace may mount.
        mount,
        umount,
        pivot_root,

        # What is actually denied. Each of these is a direct route to
        # reading or writing memory and hardware that no application has a
        # legitimate reason to touch, and each is a step in a real
        # privilege-escalation chain rather than a hypothetical one.
        deny /dev/mem rwklx,
        deny /dev/kmem rwklx,
        deny /dev/port rwklx,
        deny /proc/*/mem w,
        deny /sys/kernel/security/apparmor/.* rwklx,
        deny capability sys_module,
        deny capability sys_rawio,
        deny capability sys_boot,
        deny capability mac_admin,
        deny capability mac_override,

        # Cross-profile ptrace. The `ptrace peer=@{profile_name}` above
        # keeps debugging working WITHIN this profile — which, since this
        # profile is universal, means normal debugging still works — while
        # this refuses tracing a process confined by a different profile,
        # the case that matters once per-app profiles exist.
        deny ptrace (trace, read) peer=/**,
      '';
    };
  };
}
