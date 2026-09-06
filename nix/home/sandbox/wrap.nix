# wrapSandboxed — the per-app sandbox's home-manager-side install hook. It
# turns `wrapSandboxed { appId = "..."; caps = [...]; } pkg` into a package
# whose binaries and desktop launchers run through `dots-sandbox run`
# instead of directly, so an app installed via `home.packages` gains the
# exact same confinement `flake/apps.nix`'s `mkSandboxedApp` already gives
# flake apps — see `.superpowers/sdd/*/wrap-contract.md` for the full
# ruling this implements (Piece 1) and why an explicit call-site wrapper
# was chosen over an overlay or a `home.packages` map.
#
# Exposed via `_module.args.wrapSandboxed` (not a plain file import) so any
# module under `nix/home/` can call it with no `with import ../sandbox/wrap.nix`
# boilerplate, the same way `dots` and `dotsSandbox` already reach every
# home module through `nix/modules/system/users.nix`'s `extraSpecialArgs`.
{
  pkgs,
  lib,
  dotsSandbox,
  ...
}:
let
  inherit (lib)
    concatStringsSep
    concatMapStringsSep
    optional
    ;

  # Single source of truth for which apps are sandboxed at all, restated
  # from `flake/apps.nix`'s own `sandboxPolicyPath`/`sandboxPolicy`/
  # `isSandboxExempt` trio rather than imported from there: that file lives
  # under `flake/`, one directory that home-manager modules (under `nix/`)
  # have no principled reason to reach into, and the two readers of this
  # JSON — a flake app wrapper and a home-manager package wrapper — have no
  # third thing to share beyond the file path itself. The policy JSON
  # remains the one place that can drift; this is a second, independent
  # reader of it, not a second copy of its data.
  sandboxPolicyPath = ../../data/sandbox-policy.json;
  sandboxPolicy = builtins.fromJSON (builtins.readFile sandboxPolicyPath);

  # `null` when `appId` has no entry at all — distinct from an entry that
  # exists but does not set `unconfined`, which is the normal sandboxed
  # case. Both `or` defaults below rely on Nix resolving a missing
  # attribute anywhere in a dotted chain (confirmed by `mkSandboxedApp`'s
  # own identical `sandboxPolicy.apps.${appId}.unconfined or false` line),
  # not just the final one.
  appPolicyOf = appId: sandboxPolicy.apps.${appId} or null;

  # Property 5: an appId the policy has never heard of, or one it marks
  # `unconfined`, is not this wrapper's to confine — same rule and reason
  # as `mkSandboxedApp`'s `isSandboxExempt`. A rollout mistake at a call
  # site (wrong `appId`, a typo, forgetting to add the policy entry) can
  # therefore only ever leave an app unwrapped, never wrap one the policy
  # explicitly excused.
  isSandboxManaged =
    appId:
    let
      appPolicy = appPolicyOf appId;
    in
    appPolicy != null && !(appPolicy.unconfined or false);

  # `rust/dots-sandbox/src/policy.rs`'s `Capability::ALL` / `as_str()`,
  # restated here in full rather than read from that crate at eval time —
  # Nix has no cheap way to ask a Rust `const` its own values without
  # building and running the binary during evaluation (import-from-
  # derivation), which is far too heavy for a check that exists purely to
  # catch a typo. Restating means the two lists CAN drift if
  # `policy.rs` gains a capability and this file is not updated; the
  # failure mode of that drift is narrow and loud, though — a brand-new
  # legal capability gets rejected here with a "legal capabilities are"
  # message that is visibly stale, not silently accepted as some other
  # meaning, so the fix is obvious the first time anyone tries to use it.
  legalCapabilities = [
    "net"
    "nix-daemon"
    "repo-read"
    "repo-write"
    "postgres"
    "settings-ro"
    "kvm"
  ];

  # `rust/dots-sandbox/src/policy.rs`'s `PathMode` enum — the same
  # restating tradeoff as `legalCapabilities` above.
  legalPathModes = [
    "rw"
    "ro"
  ];

  # A typo in a capability or path-mode name is exactly what declaring caps
  # at the install site (rather than trusting a runtime lookup) is meant to
  # catch, per the contract: failing the Nix build with the offending
  # value and the legal set beats `dots-sandbox` silently ignoring an
  # override-only-shaped capability at launch time, which is where a
  # runtime check would otherwise first notice.
  checkCapability =
    appId: cap:
    if lib.elem cap legalCapabilities then
      cap
    else
      throw ''
        wrapSandboxed: app "${appId}" declares capability "${cap}", which is not one rust/dots-sandbox/src/policy.rs's Capability::as_str() recognizes.
        Legal capabilities are: ${concatStringsSep ", " legalCapabilities}.
      '';

  checkPathMode =
    appId: path: mode:
    if lib.elem mode legalPathModes then
      mode
    else
      throw ''
        wrapSandboxed: app "${appId}" grants path "${path}" mode "${mode}", which is not one rust/dots-sandbox/src/policy.rs's PathMode recognizes.
        Legal modes are: ${concatStringsSep ", " legalPathModes}.
      '';

  dotsSandboxExe = lib.getExe dotsSandbox;

  wrapSandboxed =
    {
      appId,
      caps,
      tier ? "vm",
      paths ? [ ],
      binaries ? null,
    }:
    pkg:
    # Property 6: a package this same function already produced carries its
    # own marker (below); wrapping it again would nest a second `dots-sandbox
    # run` shim inside the first instead of leaving the mechanism a no-op,
    # so that marker is checked before anything else here runs.
    if pkg.passthru.dotsSandboxWrapped or false then
      pkg
    else if !(isSandboxManaged appId) then
      pkg
    else
      let
        # Each element is only actually forced (running `checkCapability`/
        # `checkPathMode`) once the derivation below is built or evaluated,
        # which is also the only branch that ever reaches this `let` — an
        # app the policy exempts from confinement never has its `caps`/
        # `paths` looked at all, matching "returns the package untouched"
        # literally: no validation side effect either.
        capsField = concatMapStringsSep "" (c: "${checkCapability appId c};") caps;
        pathsField = concatMapStringsSep ";" (p: "${p.path}:${checkPathMode appId p.path p.mode}") paths;

        desktopKeys = concatStringsSep "\n" (
          [
            "X-Dots-Sandbox-AppId=${appId}"
            "X-Dots-Sandbox-Caps=${capsField}"
            "X-Dots-Sandbox-Tier=${tier}"
          ]
          ++ optional (paths != [ ]) "X-Dots-Sandbox-Paths=${pathsField}"
        );

        # One shim body per wrapped package, not per binary: every name in
        # `binaries` (or every name `bin/` already has, see below) gets the
        # IDENTICAL script, symlinked under its own name. The shim recovers
        # which binary it is standing in for from its own invoked path
        # ($0 — the shebang mechanism hands the interpreter the exact path
        # `execve` was called with, never the symlink's resolved target),
        # so there is exactly one script to generate regardless of how many
        # binaries this package ships, and — critically for the
        # `binaries = null` default — no need to know their names at Nix
        # eval time at all, only at build time inside postBuild below.
        #
        # DOTS_SANDBOX=0 bypasses before `dots-sandbox` is ever invoked, and
        # the exact-match "0" (not a truthiness test) — both for the exact
        # reason `flake/apps.nix`'s `mkSandboxedApp` comment already gives
        # at length: the bypass must survive `dots-sandbox` itself being the
        # broken thing, and an ambiguous value must fail toward staying
        # confined, not toward falling out of the sandbox by accident.
        # `launch.rs` already forwards SIGINT/SIGTERM/SIGHUP and the child's
        # own exit code, so this shim does no signal handling of its own —
        # a trap here would only get in that forwarding's way.
        shim = pkgs.writeShellScript "${appId}-dots-sandbox-shim" ''
          name="$(basename -- "$0")"
          original="${pkg}/bin/$name"
          if [ "''${DOTS_SANDBOX:-1}" = "0" ]; then
            exec "$original" "$@"
          fi
          exec ${lib.escapeShellArg dotsSandboxExe} run --app ${lib.escapeShellArg appId} -- "$original" "$@"
        '';

        # `awk`, not `sed`, because property 4 needs group-awareness that a
        # line-at-a-time substitution cannot express: the X-Dots-Sandbox-*
        # keys belong ONLY inside `[Desktop Entry]`, never inside a
        # `[Desktop Action ...]` group that might follow it in the same
        # file, while `Exec=` itself must be rewritten in BOTH. `keys` is
        # printed once, right before whatever group line ends `[Desktop
        # Entry]` (the next `[...]` header, or EOF if there is none) —
        # where inside that group it lands does not matter, `.desktop`
        # parsers do not care about key order.
        rewriteDesktopEntry = pkgs.writeShellScript "${appId}-dots-sandbox-desktop-rewrite" ''
          awk -v prefix=${lib.escapeShellArg "${dotsSandboxExe} run --app ${appId} -- "} \
              -v keys=${lib.escapeShellArg desktopKeys} '
            /^\[/ {
              if (inEntry && !appended) { print keys; appended = 1 }
              inEntry = ($0 == "[Desktop Entry]")
              print
              next
            }
            /^Exec=/ {
              val = $0
              sub(/^Exec=/, "", val)
              print "Exec=" prefix val
              next
            }
            { print }
            END {
              if (inEntry && !appended) print keys
            }
          ' "$1" > "$2"
        '';
      in
      pkgs.symlinkJoin {
        name = "${appId}-sandboxed";
        paths = [ pkg ];
        # Carried over from the wrapped package so a caller that already
        # relies on `pkg.meta.mainProgram` (e.g. `lib.getExe`) or a
        # passthru attribute another module reads (`claude-desktop.nix`'s
        # `skillsPlugin`) keeps seeing it on the wrapped result — this is
        # additive on top of the wrapped package, not the thing property 1
        # is about (which is about `$out`'s own directory tree).
        meta = pkg.meta or { };
        passthru = (pkg.passthru or { }) // {
          dotsSandboxWrapped = true;
          dotsSandboxAppId = appId;
        };
        # `symlinkJoin` (via `lndir`) already gave every path in `pkg` a
        # same-relative-path symlink under `$out` — property 1. Everything
        # below only replaces the specific entries properties 2 and 4 name;
        # nothing else in the tree is touched.
        postBuild = ''
          ${
            if binaries == null then
              # Default: every name already under bin/ — discovered here,
              # at build time, from the tree `symlinkJoin` just produced,
              # rather than at Nix eval time. Reading `pkg`'s own `bin/`
              # listing during evaluation would mean either building `pkg`
              # during evaluation (import-from-derivation, expensive and
              # usually disabled) or trusting a store path that may not
              # exist yet — this sidesteps both, at the cost of nothing
              # since the shim's own $0 trick (above) needs no upfront name
              # list either way.
              ''
                if [ -d "$out/bin" ]; then
                  for f in "$out"/bin/*; do
                    [ -e "$f" ] || continue
                    rm -f "$f"
                    ln -s ${shim} "$f"
                  done
                fi
              ''
            else
              ''
                mkdir -p "$out/bin"
                for name in ${lib.escapeShellArgs binaries}; do
                  rm -f "$out/bin/$name"
                  ln -s ${shim} "$out/bin/$name"
                done
              ''
          }

          if [ -d "$out/share/applications" ]; then
            for f in "$out"/share/applications/*.desktop; do
              [ -e "$f" ] || continue
              tmp="$(mktemp)"
              ${rewriteDesktopEntry} "$f" "$tmp"
              mv "$tmp" "$f"
              chmod 644 "$f"
            done
          fi
        '';
      };
in
{
  _module.args.wrapSandboxed = wrapSandboxed;
}
