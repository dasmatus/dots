# apps.${system} — the retired Justfile, now nix-native. Each app is a pinned
# shell script (pkgs.writeShellApplication); run with `nix run .#<name>` (or
# `nix run .` for the default = recipe list). `cdRepoRoot` makes them work
# from any subdir — `nix run` doesn't auto-cd to the flake root the way `just`
# did, and cargo needs the user's writable checkout, not the read-only flake
# store path.
{ pkgs, lib, ... }:
self:
let
  cdRepoRoot = ''
    __dots_root="$PWD"
    while [[ ! -f "$__dots_root/flake.nix" ]]; do
      if [[ "$__dots_root" == "/" ]]; then
        echo "not running inside a flake checkout (no flake.nix upward from $PWD)" >&2
        exit 1
      fi
      __dots_root="$(dirname "$__dots_root")"
    done
    cd "$__dots_root"
  '';

  # The shell's QML tree, linted below. Built rather than read from
  # nix/home/desktop/quickshell/qml because Theme.qml is generated from
  # nix/data/palette.json and only exists in the built tree.
  quickshellConfig = self.packages.${pkgs.stdenv.hostPlatform.system}.quickshell-config;

  # Build a LiveISO closure into result-iso. Plain (unsigned) — Secure Boot
  # was removed; the ISO boots through plain OVMF / firmware defaults. The
  # installed system uses systemd-boot + TPM2 auto-unlock (no UKI signing).
  #
  # Pure eval, no --impure. Both of the reasons this call used to need it are
  # gone now that nix/data/{settings.nix,facter.json} are real in-tree files
  # rather than committed symlinks into /var/lib/dots: pure eval no longer
  # has an absolute path outside the flake to refuse, and iso-full no longer
  # reaches a 0600-root facter.json through one (that was a permissions
  # failure --impure never fixed anyway). See nix/data/settings.nix's header.
  mkIsoApp =
    { name, target ? "iso" }:
    {
      type = "app";
      program =
        (pkgs.writeShellApplication {
          inherit name;
          # `nix` itself is not on the ambient PATH by name — see the
          # runtimeInputs comment on nix-lint below for why this has to
          # be a runtimeInput rather than the ambient
          # /run/current-system/sw/bin/nix.
          runtimeInputs = [ pkgs.nix ];
          text = ''
            ${cdRepoRoot}
            nix build .#${target} -o result-iso
          '';
        })
        + "/bin/${name}";
    };

  # Sugar: wrap a writeShellApplication into an app attrset. Every app here
  # runs unwrapped now (Phase E, ruling R3, retired the bwrap-tier
  # `dots-sandbox` these ten apps used to route through — see git history):
  # `rust/dots-sandbox`'s `container`/`vm` tiers never started at all
  # (nixpkgs' systemd has no BPF-LSM and `systemd-nsresourced` refused to
  # hand out a UID range), and four of the eight sandboxed CLI apps already
  # needed `DOTS_SANDBOX=0` just to reach `nix`'s own `nix-command`/`flakes`
  # config, which the bwrap tier's tmpfs $HOME and stripped-down bind mounts
  # never exposed. These are developer tools run against the caller's own
  # checkout, not GUI apps handling untrusted input — Flatpak (nix/home/base/
  # flatpaks.nix) is where confinement now actually lives.
  mkShellApp =
    name: args:
    {
      type = "app";
      program = (pkgs.writeShellApplication (args // { inherit name; })) + "/bin/${name}";
    };
in
{
  # This script is internally named "dots-list" for historical reasons; the
  # flake attribute (and therefore what `nix run .#default` resolves) is
  # "default".
  default = mkShellApp "dots-list" {
    text = ''
      ${cdRepoRoot}
      echo "tokyonight-dots — nix run .#<app>"
      echo
      echo "  dev                    enter the devenv dev shell (nix develop --no-pure-eval)"
      echo "  nix-lint               flake eval + cargo fmt/clippy/test for every crate"
      echo "  home-switch            apply homeConfigurations (standalone home-manager, non-NixOS host)"
      echo "  iso                    build the LiveISO (plain, unsigned)"
      echo "  iso-full               same, with intel+amd system closures embedded"
      echo "  nix-smoke              NixOS VM test: boot the LiveISO under OVMF+TPM2"
      echo "  nix-smoke-interactive  test driver Python REPL"
      echo "  enroll-fido            enroll a FIDO2/U2F key as a mandatory 2FA factor"
      echo "  clean                  remove local build/test leftovers"
    '';
  };

  # Apply the standalone home-manager profile (flake/home.nix) on a non-NixOS
  # host. The NixOS system has no use for this — there, home-manager runs as a
  # NixOS module and `nixos-rebuild switch` applies the home profile as part of
  # the system generation.
  #
  # The default ref is `.#"$USER"`, resolved at run time, NOT a bare `.#`.
  # A bare `.#` would lean on home-manager's own attribute derivation, which
  # tries "$USER@$(hostname -s)" first — the RUNNING host's name, which has no
  # reason to equal `settings.hostname` (an install answer for the NixOS
  # system, not a description of whatever host the portable profile is applied
  # to). flake/home.nix exposes the configuration under the bare username too
  # for exactly this case, so naming that key directly makes the default work
  # on any host without depending on home-manager's fallback order. Pass an
  # explicit `.#user@host` as the first argument to override.
  home-switch = mkShellApp "home-switch" {
    # coreutils for the `id -un` fallback below; writeShellApplication keeps
    # the ambient PATH, but this app must not depend on the caller's.
    runtimeInputs = [
      pkgs.nix
      pkgs.coreutils
    ];
    text = ''
      ${cdRepoRoot}
      # `nix run` the pinned home-manager from the flake's own lock rather
      # than requiring a `home-manager` binary on PATH — on a foreign host
      # there usually is not one, and an out-of-tree copy would apply a
      # different home-manager version than the one this config was evaluated
      # against.
      # An explicit flake ref may be given as the first argument
      # (`nix run .#home-switch -- .#other@host`); anything else is passed
      # straight through to `home-manager switch`. Detected by the `#` rather
      # than by position so a leading flag (`-n`, `-v`) is not mistaken for a
      # ref and swallowed.
      flake=".#''${USER:-$(id -un)}"
      if [ "$#" -gt 0 ]; then
        case "$1" in
          *"#"*)
            flake="$1"
            shift
            ;;
        esac
      fi

      # First switch on a foreign host lands on top of dotfiles that host's
      # own packages already wrote (~/.config/fish, ~/.config/git,
      # ~/.config/kitty, the GTK settings.ini pair …). Home-manager REFUSES to
      # overwrite an unmanaged file: it aborts activation at the first
      # collision, so without a backup extension the run applies nothing and
      # the only way forward is deleting host files by hand until it gets
      # through. `-b backup` renames each collision to `<file>.backup`
      # instead — reversible, and it leaves the host's own version recoverable
      # rather than gone. Skipped when the caller supplies their own, since
      # home-manager rejects the option twice.
      backup=(-b backup)
      for a in "$@"; do
        case "$a" in
          -b | --backup-extension)
            backup=()
            break
            ;;
        esac
      done

      exec nix run .#hm-cli -- switch "''${backup[@]}" --flake "$flake" "$@"
    '';
  };

  # `nix develop --no-pure-eval`, spelled once. devenv reads the checkout root
  # out of the environment, which pure flake evaluation does not expose, so the
  # bare `nix develop` this repo used to document now yields a shell pointed at
  # flake/devenv.nix's placeholder root — it opens, but its `.devenv` state and
  # its git hooks go nowhere useful. Rather than leave that as a footgun spelled
  # out only in a comment, this app is the entry point.
  dev = mkShellApp "dev" {
    runtimeInputs = [ pkgs.nix ];
    text = ''
      ${cdRepoRoot}
      exec nix develop --no-pure-eval "$@"
    '';
  };

  # Static gate: flake eval (--no-build), then fmt/clippy/test for every Rust
  # crate in the repo. Cargo is pinned in runtimeInputs so the dev shell need
  # not be on.
  #
  # pkgs.nix is pinned here for the same reason: this script calls `nix`
  # by bare name three times below, and writeShellApplication only puts
  # runtimeInputs on PATH, not the caller's own environment.
  nix-lint = mkShellApp "nix-lint" {
    runtimeInputs = [
      pkgs.nix
      pkgs.cargo
      pkgs.rustc
      pkgs.rustfmt
      pkgs.clippy
      pkgs.qt6.qtdeclarative
      pkgs.findutils
    ];
    text = ''
      ${cdRepoRoot}

      # qmllint over the shell's QML, before the flake eval simply because it
      # is the cheaper gate — fail on a QML typo without paying for a full
      # evaluation first. (It also used to be the only gate that ran locally
      # at all, back when nix/data/settings.nix was a symlink into
      # /var/lib/dots and `nix flake check` could not evaluate a bare
      # checkout; that is fixed, so this ordering is now just economy.)
      #
      # Neither Quickshell's modules nor Qt's own are on qmllint's default
      # import path, so both are passed with -I; without them every import is
      # unresolved and the real warnings drown.
      #
      # uncreatable-type is off because Quickshell registers PanelWindow (and
      # its siblings) as isCreatable: false and substitutes the Wayland or X11
      # implementation at creation time. qmllint cannot see through that
      # indirection and flags every window in the tree.
      # --max-warnings 0 because qmllint exits 0 on warnings by default, and
      # everything it reports here is a warning. Without it the gate prints the
      # problem, returns success, and gets ignored, which is worse than not
      # running it.
      #
      # -o -name '*.js' too: qmllint lints .pragma library files the same as
      # .qml (confirmed against common/hls.js — it catches a real syntax
      # error there, not a silent skip). Without it, common/'s .js helpers
      # sit outside the gate entirely and nothing here would have caught a
      # broken one.
      find "${quickshellConfig}" \( -name '*.qml' -o -name '*.js' \) -print0 | xargs -0 -r qmllint \
        --max-warnings 0 \
        --uncreatable-type disable \
        -I "${pkgs.quickshell}/lib/qt-6/qml" \
        -I "${pkgs.qt6.qtdeclarative}/lib/qt-6/qml" \
        -I "${quickshellConfig}"

      # QtTest over tests/qml. qmllint type-checks the shell but cannot see a
      # unit error — Quickshell hands UPower's percentage over as a 0-1
      # fraction and the pill wants whole percent, which type-checks either
      # way and shows an empty battery on a half-full one. Offscreen because
      # the runner still wants a QPA plugin with nothing to draw.
      #
      # QML_XHR_ALLOW_FILE_READ=1 because tst_monitor_parity.qml reads its
      # fixtures/ JSON via a synchronous XMLHttpRequest — QtQml refuses GET on
      # a file:// URL by default and the test would throw "Invalid state"
      # rather than run without this.
      QT_QPA_PLATFORM=offscreen QML_XHR_ALLOW_FILE_READ=1 qmltestrunner \
        -import "${pkgs.qt6.qtdeclarative}/lib/qt-6/qml" \
        -input tests/qml

      # palette-eval reads Theme.qml out of a BUILT quickshell-config
      # (flake/checks.nix: `builtins.readFile
      # "''${self.packages.''${system}.quickshell-config}/Theme.qml"`), which is
      # import-from-derivation. `nix flake check --no-build` refuses to realize
      # it, so on a cold store that check dies with
      #
      #   error: path '/nix/store/...-dots-quickshell-config.drv' is not valid
      #
      # an error that points at the store rather than at the cause. It passes
      # on a warm store only because some earlier build happened to leave the
      # derivation lying around, which makes this gate quietly dependent on
      # what is already in /nix/store. A fresh clone hits it immediately, and
      # so does any machine where nix.gc has run since the last shell build —
      # `--delete-older-than 0d`, weekly, per nix/modules/services/maintenance.nix.
      #
      # Same shape as the dots-skills-primer build below, different symptom:
      # there --no-build silently SKIPS an assert, here it FAILS a check that
      # is fine.
      nix build .#quickshell-config --no-link

      nix flake check --no-build

      cd rust/installer-tui && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
      cd ../settings-global && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
      cd ..

      # nix flake check --no-build only evaluates derivations, so it never
      # realizes dots-skills-primer and never runs dots-skills-primer.py's
      # asserts. Building it here is the only place in this gate that does.
      nix build .#dots-skills-primer --no-link

      cd dots-secreport && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test && cd ..
    '';
  };

  iso = mkIsoApp {
    name = "iso";
  };
  iso-full = mkIsoApp {
    name = "iso-full";
    target = "iso-full";
  };

  # Boot the ISO under OVMF + TPM2 (NixOS VM test). Pass args via
  # `nix run .#nix-smoke -- …`.
  #
  # Pure eval — the nix/data/settings.nix symlink that forced --impure here is
  # gone (real in-tree file now), see
  # mkIsoApp above. This is exactly the check the scheduled vm-boot CI job
  # runs — ci.yml:235 does `nix build -L ".#checks.x86_64-linux.${{
  # matrix.check }}"`, matrixed over iso-boot and limine-install-boot —
  # and that job has no settings.nix stub, unlike nix-eval. So vm-boot
  # runs iso-boot pure right now and dies at eval on the settings.nix path
  # through nix/modules/system/network.nix. That's a separate, pre-existing gap
  # in ci.yml, not something this fix touches.
  nix-smoke = mkShellApp "nix-smoke" {
    # pkgs.nix — see the runtimeInputs comment on nix-lint above for why a
    # bare `nix` call needs this pinned rather than relying on the ambient
    # PATH.
    runtimeInputs = [ pkgs.nix ];
    text = ''
      ${cdRepoRoot}
      nix build -L ".#checks.x86_64-linux.iso-boot" "$@"
    '';
  };

  # Debug the ISO boot test in the driver's interactive Python REPL
  # (.#checks.x86_64-linux.iso-boot.driverInteractive).
  #
  # Pure eval — the nix/data/settings.nix symlink that forced --impure here is
  # gone (real in-tree file now), see
  # mkIsoApp above.
  nix-smoke-interactive = mkShellApp "nix-smoke-interactive" {
    text = ''
      ${cdRepoRoot}
      nix run .#checks.x86_64-linux.iso-boot.driverInteractive
    '';
  };

  # Enroll a FIDO2/U2F key as a MANDATORY second factor for hyprlock, the ly
  # display manager and console login (2FA: key + password — both required).
  # Run once PER KEY — tap the key when prompted. Each run appends one line
  # to ~/.config/Yubico/u2f_keys. After enrolling, lock (hyprlock) or log
  # out: TAP THE KEY FIRST, then type your password and Enter — both are
  # required. NB: hyprlock shows "Password:" even during the touch phase
  # (hyprlock issue #723), so just tap when the screen is up. `pamu2fcfg`
  # ships in pkgs.pam_u2f.
  enroll-fido = mkShellApp "enroll-fido" {
    runtimeInputs = [ pkgs.pam_u2f ];
    text = ''
      mkdir -p ~/.config/Yubico
      touch ~/.config/Yubico/u2f_keys
      chmod 600 ~/.config/Yubico/u2f_keys
      pamu2fcfg >> ~/.config/Yubico/u2f_keys
      echo "Key enrolled ($(wc -l < ~/.config/Yubico/u2f_keys) key(s) total). Run again for each extra key."
    '';
  };

  # Remove local build/test leftovers (safe — all gitignored). `rm -rf`
  # touching the wrong tree is the one way this app could have anything to
  # lose; cdRepoRoot above is what keeps it aimed at the checkout it was run
  # from rather than $PWD's parents.
  clean = mkShellApp "clean" {
    text = ''
      ${cdRepoRoot}
      rm -rf -- result result-* *.qcow2 vm-state-*
      echo "cleaned build + VM-test leftovers"
    '';
  };
}
