# Per-application memory caps — the whole policy, in one table.
#
# Nothing in this repo bounded application memory before this file: a grep for
# MemoryMax/MemoryHigh/LimitAS/ulimit/oomd over every *.nix returned nothing,
# and the only memory-adjacent knobs were vm.swappiness
# (nix/modules/system/form-factor.nix) and swap sizing (nix/system/disko.nix).
# One leaking Electron app or a runaway `claude` session could take the whole
# desktop with it.
#
# The shape is throttle-then-kill. MemoryHigh is a soft ceiling: the kernel
# forces reclaim on the cgroup and the app slows down, but nothing dies.
# MemoryMax is the hard wall above it, and crossing it is a cgroup OOM kill.
# An app that briefly spikes is throttled; only a genuine runaway is killed.
#
# ── Why every entry also carries a swap bound ───────────────────────────────
# MemoryMax alone is NOT a hard wall on this machine, and the first version of
# this file was wrong about that. In cgroup v2 `memory.max` bounds anonymous
# and page-cache memory; it does not bound swap. Pressing against it makes the
# kernel reclaim, and reclaim means swapping out — so with unlimited swap a
# cgroup stays under its ceiling indefinitely by growing into swap instead,
# and the kill never comes.
#
# Measured here, not reasoned about: a probe under MemoryHigh=100M
# MemoryMax=200M with swap left at the default `infinity` allocated 2000 MiB
# and exited 0. The cap was live the whole time — it simply cannot bind while
# there is somewhere to reclaim to. This host makes it worse than average:
# swap is 8 GiB of zram and nothing else, so "swapping out" costs no disk I/O
# at all and the escape hatch is very fast.
#
# MemorySwapMax=0 is the wrong correction. The same probe with swap pinned to
# zero LIVELOCKED: stuck at exactly MemoryHigh, making no progress and never
# being killed, because reclaim had nowhere to go and MemoryHigh became an
# absolute barrier rather than a throttle. Worse than either failure mode.
#
# So every entry bounds swap to a finite, non-zero value. Throttling still has
# somewhere to reclaim to (so MemoryHigh throttles rather than livelocks), and
# once that allowance is exhausted reclaim genuinely fails and MemoryMax
# fires. The real ceiling of an entry is therefore max + swap, of which the
# swap half costs roughly a quarter of its size in RAM — zram on this box is
# compressing at about 4:1 (1.2 G of data in 305 M).
#
# ── Why cgroups and not a runtime flag ──────────────────────────────────────
# NODE_OPTIONS=--max-old-space-size was the obvious first answer and it is a
# dead end here: the `claude` CLI ships as a ~308 MB Bun-compiled standalone
# ELF and there is no `node` on either target at all. There is no V8 heap knob
# to turn from outside the process, so a cgroup limit is the only mechanism
# that can bound it. It is also the better one for the Electron apps, because
# it covers renderer and GPU memory that a JS heap cap never sees.
#
# ── Two levers, and why both are needed ─────────────────────────────────────
# A cgroup limit needs a unit to hang off. Which units exist depends on who
# launched the app, and that differs between this repo's two targets:
#
#   flatpak apps    Flatpak calls StartTransientUnit itself on every launch,
#                   so `app-flatpak-<id>-<instance>.scope` exists on GNOME and
#                   on Hyprland alike. A drop-in is enough — no launch-path
#                   change at all. This is `flatpakApps` below.
#
#   GNOME-launched  gnome-session-service scopes .desktop launches as
#                   `app-gnome-<desktop-id>-<pid>.scope`. Also drop-in-able,
#                   but only on the foreign host. This is `gnomeApps` below.
#
#   everything else No scope. The CLI inherits its terminal tab's cgroup
#                   (observed: app.slice/ptyxis-spawn-<uuid>.scope), and on
#                   NixOS nothing scopes GUI apps either —
#                   services.displayManager.defaultSession = "hyprland-uwsm"
#                   (nix/modules/system/core.nix) puts the COMPOSITOR under
#                   uwsm, but nix/home/desktop/hyprland.nix launches apps
#                   through `hl.dsp.exec_cmd(...)`, a direct exec. These need
#                   `wrapCapped` below.
#
# The wrapper is the portable primitive; the drop-ins are a free win wherever
# a scope already exists. `wrapCapped`'s shim reconciles the two at runtime
# rather than at eval time — see the comment on it.
#
# ── Verified, not assumed ───────────────────────────────────────────────────
# Two facts this file depends on were confirmed on the live host rather than
# reasoned about, because both would fail silently:
#
#   * `memory` is delegated to the user manager (subtree_control on
#     user@1000.service reads "cpu io memory pids"). Without that, every
#     setting here would be accepted and do nothing.
#   * dash-truncated drop-ins really do apply to TRANSIENT scopes. The proof
#     is already on the machine: gnome-session ships
#     /usr/lib/systemd/user/app-flatpak-.scope.d/override.conf, and
#     `systemctl --user show <a live flatpak scope> -p DropInPaths` lists it
#     merged into a unit whose own file says "created programmatically via
#     the systemd API. Do not edit."
{
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mapAttrs' nameValuePair concatStringsSep;

  # ── The policy ────────────────────────────────────────────────────────────
  # 14 GiB RAM, 8 GiB zram swap. Pool ceilings deliberately sum to more than
  # RAM: MemoryMax is a per-cgroup wall, not a reservation, so over-commitment
  # is normal and correct. The goal is "no single app or family can eat the
  # machine", not "the sum is provably safe" — systemd-oomd and the kernel OOM
  # killer stay the final backstop.
  #
  # A pool's `max` must be >= the largest per-app `max` inside it, or the pool
  # binds first and the per-app number is decoration. That is why the claude
  # pool is 12G against nix/home/ai/claude.nix's 10G per-app ceiling.
  pools = {
    claude = {
      high = "8G";
      max = "12G";
      swap = "3G";
      description = "Claude Code CLI sessions";
    };
    electron = {
      high = "5G";
      max = "6G";
      swap = "2G";
      description = "Electron desktop applications";
    };
    browser = {
      high = "6G";
      max = "8G";
      swap = "3G";
      description = "Web browsers";
    };
  };

  # Flatpak apps, keyed by app id. Capped through their own transient scope,
  # identically on both targets.
  #
  # Brave and LibreWolf are NOT Electron — Brave is a full Chromium build and
  # LibreWolf is Gecko — and they are here on the browser budget rather than
  # the Electron one because a tab-heavy session legitimately needs several GB
  # and must not spend its life being throttled.
  flatpakApps = {
    "com.bitwarden.desktop" = {
      pool = "electron";
      high = "2G";
      max = "3G";
      swap = "1G";
    };
    "dev.vencord.Vesktop" = {
      pool = "electron";
      high = "2G";
      max = "3G";
      swap = "1G";
    };
    "md.obsidian.Obsidian" = {
      pool = "electron";
      high = "2G";
      max = "3G";
      swap = "1G";
    };
    "org.signal.Signal" = {
      pool = "electron";
      high = "2G";
      max = "3G";
      swap = "1G";
    };
    "com.brave.Browser" = {
      pool = "browser";
      high = "4G";
      max = "6G";
      swap = "2G";
    };
    "io.gitlab.librewolf-community" = {
      pool = "browser";
      high = "4G";
      max = "6G";
      swap = "2G";
    };
  };

  # GNOME-scoped .desktop launches, keyed by desktop-file id. Only the foreign
  # host produces these units; on NixOS the directory is simply never matched
  # by anything, which costs nothing. Claude Desktop is wrapped as well (see
  # nix/home/ai/claude-desktop.nix) — this entry is what lets the shim stand
  # down under GNOME so gnome-shell keeps the scope it uses for app tracking.
  gnomeApps = {
    "com.anthropic.Claude" = {
      pool = "electron";
      high = "3G";
      max = "4G";
      swap = "1G";
    };
  };

  # ── Unit-name escaping ────────────────────────────────────────────────────
  # Flatpak builds its scope name by escaping the app id with its own routine
  # (common/flatpak-run.c): anything outside [a-zA-Z0-9:_.] becomes \xNN, then
  # the escaped id and instance id are joined with LITERAL dashes as field
  # separators. So dots survive untouched and dashes do not — confirmed in the
  # journal, which carries both
  #   app-flatpak-com.brave.Browser-2317004770.scope
  #   app-flatpak-io.gitlab.librewolf\x2dcommunity-1019711180.scope
  #
  # Only those literal separator dashes are truncation points for the drop-in
  # directory name; a \x2d inside the id is not one.
  #
  # `-` is the only escaped character any id here actually contains, so the
  # mapping is a replaceStrings rather than a general char-by-char escaper.
  # The guard below is what keeps that honest: an id carrying anything else
  # this mapping would get wrong fails the build instead of silently
  # generating a directory that never matches a real unit. A cap that quietly
  # does nothing is the failure worth engineering out — it looks installed.
  assertEscapable =
    id:
    if builtins.match "[a-zA-Z0-9:_.-]+" id != null then
      id
    else
      throw ''
        memory-limits: app id "${id}" contains a character flatpak escapes in a
        way escapeUnitId does not implement (only `-` -> \x2d is handled).
        Extend escapeUnitId before adding it.
      '';

  escapeUnitId = id: builtins.replaceStrings [ "-" ] [ "\\x2d" ] (assertEscapable id);

  sliceOf = pool: "dots-${pool}.slice";

  # One drop-in per app. `[Scope]` is the right section for a scope unit;
  # MemoryHigh/MemoryMax/Slice are all systemd.resource-control(5) settings,
  # which that section takes.
  #
  # Slice= here was the one setting in this file whose effect was in doubt.
  # Flatpak sends StartTransientUnit exactly one property (PIDs) and never
  # Slice, so the scope defaults to app.slice and a drop-in ought to be free
  # to move it — but systemd's unit_set_slice() refuses with -EBUSY once a
  # unit is cgroup-bound, and upstream issue #3240 reproduced a drop-in Slice=
  # being silently ignored on systemd 229.
  #
  # On 259 it MOSTLY works, and the failure is a race rather than a flat no.
  # Measured over five launches, reading back the live unit rather than the
  # file: four landed in
  #   .../dots.slice/dots-electron.slice/app-flatpak-md.obsidian.Obsidian-*.scope
  # and one landed in .../app.slice/app-flatpak-*.scope despite `systemctl
  # --user show -p Slice` reporting dots-electron.slice for it. That is the
  # -EBUSY window: the property is merged onto the unit either way, but if
  # systemd realizes the cgroup before the drop-in lands, the move is refused
  # and only the placement is lost. The miss was observed right after a large
  # activation plus daemon-reload, i.e. when the manager was busiest.
  #
  # This is a DEGRADED mode, not a broken one, and it is why the per-app
  # numbers above are not expressed as pool shares: on a missed launch the app
  # still carries its own MemoryHigh/MemoryMax/MemorySwapMax — all five
  # launches had those exactly right — it simply is not counted against the
  # family pool for that run. Do not add anything here that only works when
  # the placement succeeds.
  #
  # If a future systemd regresses this outright, drop this one line: the apps
  # keep their individual caps and lose only the family pool.
  #
  # There is no fallback worth preferring: flatpak exposes no config key or
  # env var to disable its scope creation, and wrapping the launch as
  # `systemd-run --scope --slice=X -- flatpak run ...` does not work — flatpak
  # unconditionally requests its own fresh scope and re-parents out of X.
  dropIn = spec: ''
    [Scope]
    MemoryAccounting=yes
    MemoryHigh=${spec.high}
    MemoryMax=${spec.max}
    MemorySwapMax=${spec.swap}
    Slice=${sliceOf spec.pool}
  '';

  mkDropIn =
    prefix: id: spec:
    nameValuePair "systemd/user/${prefix}-${escapeUnitId id}-.scope.d/50-dots-memory.conf" {
      text = dropIn spec;
    };

  # ── The wrapper ───────────────────────────────────────────────────────────
  # For the binaries that never get a usable scope. Mirrors the shape of
  # nix/home/sandbox/wrap.nix's wrapSandboxed — one shim body per package,
  # symlinked under every name in bin/, recovering which binary it stands in
  # for from $0 — rather than inventing a second wrapper convention in this
  # repo.
  wrapCapped =
    {
      pool,
      high,
      max,
      swap,
    }:
    pkg:
    # Same idempotence guard as wrapSandboxed: wrapping an already-wrapped
    # package would nest a second shim rather than leave the mechanism alone.
    if pkg.passthru.dotsMemoryCapped or false then
      pkg
    else
      let
        shim = pkgs.writeShellScript "dots-memory-cap-shim" ''
          name="$(basename -- "$0")"
          original="${pkg}/bin/$name"

          # Exact-match bypass, not a truthiness test — the same reasoning
          # DOTS_SANDBOX=0 carries in nix/home/sandbox/wrap.nix. This shim
          # stands in front of binaries needed to repair a broken machine, so
          # an ambiguous value stays capped rather than falling out of the cap
          # by accident.
          if [ "''${DOTS_MEMORY_CAP:-1}" = "0" ]; then
            exec "$original" "$@"
          fi

          # Already inside a capped cgroup? Then a drop-in (GNOME, flatpak) or
          # an outer shim got here first, and nesting a second scope would add
          # a cgroup level for nothing — worse, under GNOME it would migrate
          # the process out of app-gnome-*.scope and leave gnome-shell holding
          # an empty unit it uses to track whether the app is running.
          #
          # This runtime check is what lets ONE module be correct on both
          # targets. nix/home/profiles/portable.nix's header notes that
          # nothing under nix/home reads osConfig, so there is no clean
          # eval-time way to ask "am I on NixOS?" — and asking is the wrong
          # question anyway. What matters is whether the job is already done.
          cg="$(cut -d: -f3 /proc/self/cgroup 2>/dev/null | head -n1)"
          if [ -n "$cg" ] && [ -r "/sys/fs/cgroup$cg/memory.max" ] &&
             [ "$(cat "/sys/fs/cgroup$cg/memory.max" 2>/dev/null)" != "max" ]; then
            exec "$original" "$@"
          fi

          # Probe before committing. exec cannot be undone, so whether the
          # fallback is reachable has to be settled while there is still a
          # process here to fall back with. Any successful round trip to the
          # user manager will do.
          #
          # Both tools are resolved from PATH at RUNTIME, never baked in: that
          # finds /usr/bin/systemd-run (host systemd 259) on the foreign
          # secureblue host and the NixOS one on NixOS. Pinning nixpkgs' own
          # systemd package here would hand a foreign host's systemd a client
          # from a different build.
          if command -v systemd-run >/dev/null 2>&1 &&
             command -v systemctl >/dev/null 2>&1 &&
             systemctl --user show --property=Version >/dev/null 2>&1; then
            exec systemd-run --user --quiet --collect --scope \
              --slice=${sliceOf pool} \
              --property=MemoryHigh=${high} \
              --property=MemoryMax=${max} \
              --property=MemorySwapMax=${swap} \
              -- "$original" "$@"
          fi

          # No user manager reachable (a TTY with no session bus, a container,
          # a rescue shell). Running uncapped beats not running.
          exec "$original" "$@"
        '';
      in
      pkgs.symlinkJoin {
        # `name` only labels the store path. `pname` is what lib.getName
        # reads, and getName is exactly what flake/home.nix:51 and
        # nix/modules/system/core.nix:34 match their allowUnfreePredicate
        # against. Renaming the package outright — the obvious first shape for
        # a wrapper — drops both Claude packages off that allowlist, and the
        # build dies with "refusing to evaluate 'claude-desktop-memory-capped'
        # because it has an unfree license". A transparency wrapper has no
        # business changing the identity of what it wraps, so pname and
        # version are carried through untouched and only the label differs.
        name = "${lib.getName pkg}-memory-capped";
        pname = lib.getName pkg;
        version = lib.getVersion pkg;
        paths = [ pkg ];
        # Every name in bin/ gets the IDENTICAL shim under its own name, so
        # there is no need to know those names at eval time — only at build
        # time, here. The shebang mechanism hands the interpreter the exact
        # path execve was called with, so $0 inside the shim is the symlink,
        # not its target, and basename recovers the original binary's name.
        #
        # .desktop files need the same treatment for a different reason:
        # nix/packages/claude-desktop.nix already substitutes Exec= to point
        # at its own $out/bin/claude-desktop, so without this the launcher
        # would walk straight past the shim to the unwrapped binary. A plain
        # prefix rewrite covers Exec= in [Desktop Entry] and in every
        # [Desktop Action ...] alike, which is exactly what is wanted — unlike
        # wrapSandboxed, this wrapper only re-points a path and never has to
        # prepend a command, so it needs no group-aware pass.
        postBuild = ''
          for f in "$out"/bin/*; do
            [ -e "$f" ] || continue
            rm -f "$f"
            ln -s ${shim} "$f"
          done

          for d in "$out"/share/applications/*.desktop; do
            [ -e "$d" ] || continue
            real="$(readlink -f "$d")"
            rm -f "$d"
            sed "s|^Exec=${pkg}/bin/|Exec=$out/bin/|" "$real" > "$d"
          done
        '';
        passthru = (pkg.passthru or { }) // {
          dotsMemoryCapped = true;
          dotsMemoryCapUnwrapped = pkg;
        };
        inherit (pkg) meta;
      };
in
{
  # Exposed through _module.args rather than a plain import, matching
  # nix/home/sandbox/wrap.nix's `_module.args.wrapSandboxed`, so a module can
  # take it as a function argument without importing this file and inheriting
  # its config. Unlike wrapSandboxed it needs no identity stub on the foreign
  # host: this module is imported by nix/home/profiles/portable.nix, which
  # both entry points take, so wrapCapped is always the real thing.
  _module.args.wrapCapped = wrapCapped;

  # The pool slices. dots.slice is declared explicitly rather than left to
  # systemd's implicit parent creation so `systemd-cgls --user` shows a named
  # tree, and so the three pools cannot drift apart under an unnamed parent.
  # NB an implicitly created slice keeps whatever settings it was born with
  # until a `systemctl --user daemon-reload`. Naming a not-yet-existing slice
  # in a `systemd-run --slice=` makes systemd invent one with NO limits, and
  # that invented unit shadows this file until the reload. home-manager issues
  # the reload on activation, so this only bites when hand-testing ahead of a
  # switch — but it bites silently: correct files on disk, infinity in the
  # kernel. Read back the live unit, never the file.
  systemd.user.slices = {
    dots.Unit.Description = "dots memory-capped applications";
  }
  // mapAttrs' (
    pool: spec:
    nameValuePair "dots-${pool}" {
      Unit.Description = "Memory pool: ${spec.description}";
      Slice = {
        MemoryAccounting = true;
        MemoryHigh = spec.high;
        MemoryMax = spec.max;
        MemorySwapMax = spec.swap;
      };
    }
  ) pools;

  # Deliberately NOT setting ManagedOOMMemoryPressure= on these slices.
  # systemd-oomd is active with stock config on the foreign host and already
  # watches PSI pressure; MemoryHigh raises pressure inside a capped cgroup by
  # design, so opting these slices into oomd's pressure killing would stack a
  # second killer with different victim selection on top of MemoryMax. One
  # wall whose behaviour is predictable beats two that interact.

  xdg.configFile =
    (mapAttrs' (mkDropIn "app-flatpak") flatpakApps) // (mapAttrs' (mkDropIn "app-gnome") gnomeApps);

  # A one-line record of what the policy actually resolved to, so the numbers
  # can be read back from a built profile without re-evaluating the flake.
  home.file.".local/share/dots/memory-limits.txt".text =
    concatStringsSep "\n" (
      [ "# generated by nix/home/base/memory-limits.nix" ]
      ++ lib.mapAttrsToList (
        pool: spec: "pool ${sliceOf pool}\thigh=${spec.high}\tmax=${spec.max}\tswap=${spec.swap}"
      ) pools
      ++ lib.mapAttrsToList (
        id: spec:
        "flatpak ${id}\thigh=${spec.high}\tmax=${spec.max}\tswap=${spec.swap}\tslice=${sliceOf spec.pool}"
      ) flatpakApps
      ++ lib.mapAttrsToList (
        id: spec:
        "gnome ${id}\thigh=${spec.high}\tmax=${spec.max}\tswap=${spec.swap}\tslice=${sliceOf spec.pool}"
      ) gnomeApps
    )
    + "\n";
}
