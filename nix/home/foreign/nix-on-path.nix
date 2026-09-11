# Making the home-manager profile reachable on a host that is not NixOS.
#
# EVERYTHING UNDER nix/home/foreign/ IS FOREIGN-HOST-ONLY. Nothing here is
# reachable from nix/home/default.nix, and nothing here may be imported from
# nix/home/profiles/portable.nix, which the NixOS build imports too. There
# /usr/bin is empty, ~/.local/bin is on no PATH, and a farm shadowing the
# system profile would be actively wrong. The single import lives in
# flake/home.nix, beside targets.genericLinux.enable.
#
# ── The problem ────────────────────────────────────────────────────────────
#
# On secureblue the session PATH is exactly
#
#   /home/matus/.local/bin:/home/matus/bin:/usr/local/sbin:/usr/local/bin:/usr/bin
#
# for gnome-shell and for the `systemd --user` manager alike, and
# ~/.nix-profile/bin is on neither. That is not just inconvenient. GLib's
# g_desktop_app_info_load_from_keyfile REJECTS a .desktop entry outright when
# TryExec, or argv[0] of Exec, is a bare name g_find_program_in_path cannot
# resolve. Of the profile's 13 desktop entries only 4 survived: the ones with
# an absolute /nix/store Exec, plus the ones whose bare name the HOST also
# provides. betterbird, kitty, nvim, kvantummanager, nm-applet, qt5ct, qt6ct
# and haveno were discarded before GNOME ever saw them, with nothing logged.
#
# XDG_DATA_DIRS was never the cause. targets.genericLinux already puts
# ~/.nix-profile/share in it, gnome-shell's own environ included. Checked
# against /proc/<gnome-shell>/environ rather than assumed.
#
# ── Two mechanisms, one policy ─────────────────────────────────────────────
#
# The policy is HOST WINS. A name the ostree layer provides keeps meaning the
# ostree layer's binary: the profile must not shadow ld, as, cc, make, strip,
# vim or man, because a toolchain half from nixpkgs and half from the host
# fails weeks later as an unrelated linker error.
#
#   localBin     a pruned symlink farm in ~/.local/bin, which PRECEDES
#                /usr/bin here. This is where EXCEPTIONS are expressed: a
#                name linked here beats the host deliberately.
#   sessionPath  ~/.nix-profile/bin APPENDED to PATH through environment.d.
#                This is where the DEFAULT is expressed: everything in the
#                profile is reachable, and nothing in it can shadow the host.
#
# One mechanism per direction. Collapsing them into a single prepended PATH
# entry would make the default wrong and leave nowhere to state an exception.
# The mirror-image argument is written out around the `profileBin` block of
# ~/.bashrc.d/nix-toolbox.sh, where the container image's toolchain must win
# and the profile is appended behind it. Only the ordering rule transfers;
# the git carve-out below inverts it.
#
# ── Why an activation script, not home.file ────────────────────────────────
#
# Listing the profile's bin/ at eval time means readDir over
# config.home.path, which IS the home-manager-path derivation. That is
# import-from-derivation: it builds the user's whole closure during
# evaluation and stops `nix flake show` working. Even granting IFD it could
# not express the rule, because "does /usr/bin/NAME exist" is a fact about
# the machine being switched, unreadable under pure evaluation and
# legitimately different on two hosts sharing this flake. The question is an
# activation-time question by construction.
#
# A linkFarm derivation symlinked at ~/.local/bin was rejected for a separate
# reason: that directory is live and shared. pipx, `cargo install`, the
# Claude launcher and the user's own scripts write into it. Replacing it with
# a read-only store symlink breaks all of them.
#
# What leaving home.file costs is its two safety properties, cleanOldGen
# pruning and checkLinkTargets' refusal to clobber unmanaged files. The
# manifest and the three-gate removal rule below re-implement both, narrower.
#
# ── Namespace ──────────────────────────────────────────────────────────────
#
# `targets.foreignHost` extends home-manager's own targets.* namespace, which
# reads correctly next to `targets.genericLinux.enable = true` at the call
# site. If upstream ever declares the same path the result is a loud option
# collision at eval, not silence, so the collision risk is acceptable.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.targets.foreignHost;
  farm = cfg.localBin;

  # NB there is deliberately no eval-time `declaredBin = "${config.home.path}/bin"`
  # here. The script is installed through home.packages, and config.home.path
  # IS the buildEnv over home.packages, so naming it closes the loop and Nix
  # fails with "infinite recursion". The script resolves the current
  # generation at RUNTIME instead, from the gcroot home-manager maintains for
  # exactly this purpose. That is also what makes it correct when run by hand
  # from a host shell, where no eval has happened at all.

  # Linked TO, though: stable, narrow, and self-describing. Pointing at
  # /nix/store/…-home-manager-path/bin would churn every link's target on
  # every generation and, decisively, make the ownership signature
  # "/nix/store/*", far too broad a thing to ever delete on.
  profileBin = "${config.home.profileDirectory}/bin";

  manifest = "${config.xdg.stateHome}/dots/nix-local-bin.list";

  # One implementation, two callers: home-manager activation, and the user
  # from a host shell after a container-based switch. Named dots-local-bin-sync
  # so it is discoverable in the profile next to the other dots-* tools.
  farmScript = pkgs.writeShellApplication {
    name = "dots-local-bin-sync";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      warn() { printf '%s\n' "$*" >&2; }

      farmDir=${lib.escapeShellArg farm.dir}
      # The generation's own package set, resolved at runtime through the
      # gcroot rather than baked in. Deliberately NOT ~/.nix-profile/bin: on
      # this host that is root's per-user profile, shared with the
      # nix-toolbox container, so enumerating it would adopt anything
      # hand-installed there by something else.
      declaredBin="''${1:-$HOME/.local/state/home-manager/gcroots/current-home/home-path/bin}"
      if [ ! -d "$declaredBin" ]; then
        warn "nix-on-path: no home-manager generation at $declaredBin - nothing to sync."
        exit 0
      fi
      profileBin=${lib.escapeShellArg profileBin}
      manifest=${lib.escapeShellArg manifest}

      # -- Are we actually looking at the host? --------------------------
      #
      # This repo's switch runs home-manager INSIDE a podman container
      # (nix-home-switch in ~/.bashrc.d/nix-toolbox.sh, nixos/nix image).
      # That container mounts $HOME at its real path and /nix, and nothing
      # else, so /usr/bin in there is the IMAGE's: one entry, against the
      # host's 2319. Every host-wins decision below reads /usr/bin, so
      # running under the container silently INVERTS the whole policy. No
      # name looks host-owned, everything gets linked, and cc, ld, make,
      # vim, man and strip end up shadowed by nixpkgs copies -- precisely
      # the breakage this module exists to prevent. Observed, not
      # hypothetical: the first switch after this module landed created 46
      # such links. So it must refuse rather than guess.
      #
      # The test is /etc/os-release, not a count threshold. A threshold is
      # arbitrary and would misfire on a genuinely minimal host; the ID is a
      # fact. Nothing under nix/home/foreign/ is ever imported on NixOS (see
      # the header), so seeing ID=nixos here means the filesystem being
      # inspected is the container's rather than this host's.
      onHost=1
      if [ ! -r /etc/os-release ]; then
        onHost=0
      elif grep -qx 'ID=nixos' /etc/os-release; then
        onHost=0
      fi

      if [ "$onHost" -ne 1 ]; then
        warn "nix-on-path: /usr/bin belongs to the build container, not the host - farm left untouched."
        warn "             Run this from a HOST shell instead:  dots-local-bin-sync"
      else

      # Names the host owns. Built first so the loop below is a lookup.
      declare -A hostHas=()
      for d in ${lib.escapeShellArgs farm.hostBinDirs}; do
        [ -d "$d" ] || continue
        for p in "$d"/*; do
          [ -e "$p" ] || continue
          hostHas["''${p##*/}"]=1
        done
      done

      # Names that override the host regardless.
      declare -A nixWins=()
      nixWinsNames=( ${lib.escapeShellArgs farm.nixWins} )
      for n in ''${nixWinsNames[@]+"''${nixWinsNames[@]}"}; do nixWins["$n"]=1; done
      nixWinsBins=( ${lib.escapeShellArgs (map (p: "${lib.getBin p}/bin") farm.nixWinsPackages)} )
      for pkgBin in ''${nixWinsBins[@]+"''${nixWinsBins[@]}"}; do
        [ -d "$pkgBin" ] || continue
        for p in "$pkgBin"/*; do
          [ -e "$p" ] || continue
          nixWins["''${p##*/}"]=1
        done
      done

      # What this generation asserts.
      declare -A want=()
      if [ -d "$declaredBin" ]; then
        for p in "$declaredBin"/*; do
          [ -e "$p" ] || [ -L "$p" ] || continue
          n="''${p##*/}"
          if [ -n "''${hostHas[$n]:-}" ] && [ -z "''${nixWins[$n]:-}" ]; then continue; fi
          want["$n"]=1
        done
      fi

      # What the previous generation claimed. Ownership comes from here and
      # nowhere else: a link matching the target shape but absent from this
      # file was made by someone else and is never touched.
      declare -A owned=()
      if [ -r "$manifest" ]; then
        while IFS= read -r n; do
          [ -n "$n" ] && owned["$n"]=1
        done < "$manifest"
      fi

      mkdir -p "$farmDir" "$(dirname "$manifest")"

      # Remove. Three gates, all of which must hold: we claimed it last time,
      # it is a symlink (never a regular file, never a directory), and its RAW
      # readlink is byte-identical to the shape we create. Raw, never
      # readlink -f: resolving through the profile into the store would make
      # an unrelated link that happens to point at the same binary look like
      # ours, and would return nothing at all for a link whose package just
      # left the profile, which is exactly the link most needing pruning.
      for n in "''${!owned[@]}"; do
        [ -n "''${want[$n]:-}" ] && continue
        entry="$farmDir/$n"
        [ -L "$entry" ] || continue
        [ "$(readlink "$entry")" = "$profileBin/$n" ] || continue
        if [ -n "''${hostHas[$n]:-}" ]; then
          warn "nix-on-path: the host now provides '$n' — dropping the nix shadow."
          warn "             Add \"$n\" to targets.foreignHost.localBin.nixWins to keep the nix one."
        fi
        rm -f "$entry"
      done

      # Create or adopt. The only branch that writes is the one where the path
      # is absent, or is already a symlink of exactly our shape. Anything else
      # at that name, a real file, a directory, someone else's symlink, is
      # reported and left alone, which is checkLinkTargets' rule re-stated for
      # the one directory home-manager is not managing.
      for n in "''${!want[@]}"; do
        entry="$farmDir/$n"
        if [ -L "$entry" ]; then
          [ "$(readlink "$entry")" = "$profileBin/$n" ] || {
            warn "nix-on-path: $entry is a symlink this module did not create — left alone."
            continue
          }
        elif [ -e "$entry" ]; then
          warn "nix-on-path: $entry exists and is not a symlink — left alone."
          continue
        else
          ln -s "$profileBin/$n" "$entry"
        fi
      done

      # Record what we now own, atomically and sorted so it diffs cleanly.
      # Only names we would have created are recorded, so a deliberate user
      # override of a host-owned name is never adopted and so never pruned.
      if [ -z "''${DRY_RUN:-}" ]; then
        tmp="$(mktemp "$manifest.XXXXXX")"
        for n in "''${!want[@]}"; do printf '%s\n' "$n"; done | LC_ALL=C sort > "$tmp"
        mv -f "$tmp" "$manifest"
      fi

      fi
    '';
  };
in
{
  options.targets.foreignHost.localBin = {
    enable = lib.mkEnableOption ''
      a pruned symlink farm in ~/.local/bin over this generation's profile,
      for a host whose session PATH does not include ~/.nix-profile/bin
    '';

    dir = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.local/bin";
      defaultText = lib.literalExpression ''"''${config.home.homeDirectory}/.local/bin"'';
      description = ''
        Where the farm is built. Must already precede the host's binary
        directories on the session PATH or the exercise is pointless, since
        nothing here manipulates PATH ordering.
      '';
    };

    hostBinDirs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "/usr/bin"
        "/usr/sbin"
        "/usr/local/bin"
        "/usr/local/sbin"
      ];
      description = ''
        Directories whose executables the host owns. A name found in any of
        them is not linked unless nixWinsPackages or nixWins covers it.

        An option rather than a constant because the answer is per-machine:
        this host also carries a /home/linuxbrew/.linuxbrew prefix that is
        not on the session PATH today but could be, and /opt/*/bin is normal
        on other distributions.
      '';
    };

    nixWinsPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      example = lib.literalExpression "[ config.programs.git.package ]";
      description = ''
        Packages whose entire bin/ overrides the host. Every name found in
        each package's bin/ at activation time is linked even on collision.

        Packages rather than names, on purpose. The motivating case is git:
        nix/home/shell/git.nix sets credential.helper = libsecret, and the
        host's /usr/libexec/git-core ships only git-credential-cache and
        git-credential-store, so the host's git cannot satisfy this
        configuration at all. The exception is not one binary either, it is
        git plus a dozen helpers, and a hand-written list of those names is a
        drift generator: nixpkgs renames one, the list quietly stops covering
        it, and it surfaces months later as "git: 'credential-libsecret' is
        not a git command".
      '';
    };

    nixWins = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Individual names that override the host, for a binary whose package
        cannot conveniently be named. Prefer nixWinsPackages.
      '';
    };
  };

  config = lib.mkIf farm.enable {
    # Ordered after installPackages, not linkGeneration. Both are declared
    # entryAfter [ "writeBoundary" ] (files.nix, home-environment.nix) and the
    # DAG gives siblings no order, so writeBoundary alone would be a race.
    # That is the lesson recorded on portable.nix's gtkSettingsIniSeed. The
    # hazard there was cleanOldGen deleting the guarded path; that hazard is
    # absent here, since home-manager manages nothing under ~/.local/bin. What
    # this script actually requires is that its link TARGETS resolve, and
    # those are installPackages' output.
    # The farm itself is a script IN THE PROFILE, not an inline activation
    # blob, because on this host activation cannot do the job. nix-home-switch
    # runs home-manager inside a podman container that mounts only $HOME and
    # /nix, so the /usr/bin it would inspect is the image's. There is no nix on
    # the host to run activation natively with, either. What there IS, once
    # /nix is a live bind mount, is the profile: ~/.nix-profile/bin/<name> runs
    # perfectly well from a host shell. So the logic lives somewhere runnable
    # from both sides, and activation merely invokes it, guarded.
    home.packages = [ farmScript ];

    home.activation.nixLocalBinFarm = lib.hm.dag.entryAfter [ "installPackages" ] ''
      ${lib.getExe farmScript} || warnEcho "nix-on-path: farm sync reported a problem (see above)."
    '';
    # The default direction: everything in the profile reachable, nothing in
    # it able to shadow the host. Appended, never prepended.
    #
    # systemd.user.sessionVariables rather than home.sessionPath, because
    # home.sessionPath reaches ONLY etc/profile.d/hm-session-vars.sh (it feeds
    # home.sessionSearchVariables, consumed solely by sessionVariablesPackage)
    # and it PREPENDS. Neither suits: ~/.bashrc on this host never sources
    # that file, and gnome-shell, the process whose PATH decides whether a
    # .desktop entry loads at all, is started by the systemd user manager,
    # which reads environment.d and not any shell rc.
    #
    # The ${PATH:+:} guard matters: an unset PATH would otherwise yield a
    # leading empty field, and an empty PATH element means the CURRENT
    # DIRECTORY, silently putting cwd on the session PATH. home-manager's own
    # genericLinux XDG_DATA_DIRS line uses this same form in this same file,
    # and it expands correctly in the live manager, so the syntax is
    # supported here rather than merely documented.
    #
    # Takes effect at the next login: environment.d is read when the user
    # manager starts. The farm above is what works immediately, which is the
    # other reason both exist.
    systemd.user.sessionVariables.PATH = "\${PATH}\${PATH:+:}${profileBin}";
  };
}
