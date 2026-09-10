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
    {
      name,
      target ? "iso",
      sandboxed ? true,
    }:
    mkSandboxedApp {
      inherit name sandboxed;
      app = {
        type = "app";
        program =
          (pkgs.writeShellApplication {
            inherit name;
            # `nix` itself is not on the sandboxed PATH by name — see the
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
    };

  # Sugar: wrap a writeShellApplication into an app attrset, then route the
  # result through mkSandboxedApp. `sandboxed` and `appId` are pulled out of
  # `args` before it reaches writeShellApplication, which has no use for
  # either. `appId ? name` covers every call site but one: every app here
  # names its writeShellApplication script after the flake attribute it is
  # bound under (`clean = mkShellApp "clean" { ... }`), except `default`,
  # whose script is called "dots-list" for historical reasons while the
  # flake attribute — and therefore the policy catalog's app id, and the
  # argument `nix run .#default` actually resolves — is "default". See
  # that definition below for the explicit override this forces.
  mkShellApp =
    name: args:
    mkSandboxedApp {
      inherit name;
      sandboxed = args.sandboxed or true;
      appId = args.appId or name;
      app = {
        type = "app";
        program =
          (pkgs.writeShellApplication (
            builtins.removeAttrs args [
              "sandboxed"
              "appId"
            ]
            // {
              inherit name;
            }
          ))
          + "/bin/${name}";
      };
    };

  # nix/data/sandbox-policy.json is the single source of truth for which
  # apps opt out of the sandbox entirely (its own `unconfined` entries,
  # each carrying its own `reason`, read here rather than restated — one
  # place that can drift instead of two). mkSandboxedApp consults it
  # directly rather than trusting its own caller, so a rollout mistake
  # below can never re-confine an app the policy already excused.
  sandboxPolicyPath = ../nix/data/sandbox-policy.json;
  sandboxPolicy = builtins.fromJSON (builtins.readFile sandboxPolicyPath);
  isSandboxExempt = appId: sandboxPolicy.apps.${appId}.unconfined or false;

  # Wraps an already-built `{ type = "app"; program = <store path>; }` —
  # mkShellApp's or mkIsoApp's own output, unmodified — so `nix run
  # .#<appId>` resolves the sandbox policy and launches through
  # `dots-sandbox run` instead of running the built script directly. This
  # is the only place that construction happens; mkShellApp and mkIsoApp
  # both route through it, which is what lets every app in this file gain
  # the mechanism without any of their ten `text` bodies changing.
  #
  # `sandboxed` now defaults to TRUE. A new app added to this file is
  # confined without its author doing anything, and un-confining one takes
  # a deliberate `sandboxed = false` that shows up in review.
  #
  # That inversion is the point. As an opt-in it stayed at two apps for the
  # entire life of the feature, because nothing forced anyone to flip it —
  # the staged rollout that existed so one flawed wrapper would break one
  # app rather than ten quietly became the reason nine apps ran unconfined.
  # The wrapper has since been exercised against a real confinement test: a
  # planted secret unreadable, the network namespace unshared, and the one
  # granted capability still working.
  #
  # DOTS_SANDBOX=0 still bypasses at run time — see the wrapper body below.
  # This is a single-user desktop, not a multi-tenant one: the wrapper's job
  # is to make confinement the default nobody has to opt into, not to be
  # tamper-proof against its own operator, who already has root and every
  # other way to disable it if they actually want to. A wrapper that cannot
  # be switched off turns any bug in dots-sandbox — a build failure, a panic
  # on startup, a policy resolved into nonsense — into an unbootable-desktop
  # event with no recovery short of `git revert`. The hatch trades that
  # failure mode for a narrower one: a stray or malicious `DOTS_SANDBOX=0`
  # in the environment, which the exact-match check below at least keeps a
  # typo from triggering by accident.
  #
  # What remains unwrapped is unwrapped on purpose, not on schedule: the
  # entries `isSandboxExempt` reads out of nix/data/sandbox-policy.json,
  # each carrying its own reason.
  #
  # `appId` is looked up against the policy independently of `sandboxed`:
  # an app the policy already marks `unconfined` is never wrapped, no
  # matter what its caller asked for. That means a rollout-list mistake
  # can only ever fail to sandbox an app that was never going to be
  # sandboxed, never accidentally confine one the policy explicitly
  # excused (nix-smoke-interactive, enroll-fido, today).
  mkSandboxedApp =
    {
      name,
      appId ? name,
      sandboxed,
      app,
    }:
    if !sandboxed || isSandboxExempt appId then
      app
    else
      {
        type = "app";
        program =
          (pkgs.writeShellApplication {
            inherit name;
            runtimeInputs = [ self.packages.${pkgs.stdenv.hostPlatform.system}.dots-sandbox ];
            text = ''
              # DOTS_SANDBOX=0 is the escape hatch for when the sandbox
              # itself is what is broken: a policy file dots-sandbox still
              # parses but resolves into nonsense, a capability-to-argv bug,
              # a systemd-nspawn incompatibility on some host. None of that
              # is something dots-sandbox can be trusted to notice about
              # itself, so this check does NOT live inside dots-sandbox (say,
              # as a flag `run_command` inspects in main.rs before doing
              # anything else) — if it did, every one of those failure modes
              # would have to be survived by the very code that might be the
              # thing failing, before the bypass could even take effect.
              # Checked here instead, in this wrapper, before dots-sandbox is
              # invoked at all, the bypass keeps working even if dots-sandbox
              # fails to build, panics on startup, or resolves a policy into
              # something actively wrong — the only version of "bypass"
              # actually worth having. A future "simplification" that moves
              # this check into the binary quietly deletes the one thing
              # this variable exists for.
              #
              # Exact-match "0" rather than a truthiness test: an unset,
              # misspelled or otherwise ambiguous value stays sandboxed,
              # because the safe failure direction for a security escape
              # hatch is staying confined, not falling out of the sandbox by
              # accident.
              if [[ "''${DOTS_SANDBOX:-1}" == "0" ]]; then
                exec "${app.program}" "$@"
              fi

              # The defaults file ships from the Nix store, read-only
              # (${sandboxPolicyPath}). DOTS_SANDBOX_DEFAULTS lets it be
              # pointed elsewhere instead — how a real install relocates it,
              # and how property 4 below gets tested against a deliberately
              # broken file. An already-set value always wins; only an
              # unset one falls back to the store path.
              export DOTS_SANDBOX_DEFAULTS="''${DOTS_SANDBOX_DEFAULTS:-${sandboxPolicyPath}}"

              # A malformed policy now REFUSES to launch rather than running
              # the app unconfined.
              #
              # This is deliberately asymmetric with DOTS_SANDBOX=0 above:
              # that bypass is an explicit, operator-set opt-out, while
              # degrading to unconfined because the policy failed to parse
              # is not a decision anyone made — it is the most dangerous
              # kind of opt-out, because it triggers exactly when something
              # is already wrong and nobody is watching. A policy file that
              # fails to parse would otherwise silently hand every app full
              # access.
              #
              # Still checked BEFORE `dots-sandbox run` rather than inferred
              # from its exit code afterwards: a launch failure and a
              # wrapped program's own non-zero exit are indistinguishable
              # after the fact, so guessing between them is how a
              # capability-denied app gets waved through on its first denial.
              if ! dots-sandbox policy validate "$DOTS_SANDBOX_DEFAULTS" >/dev/null; then
                echo "dots-sandbox: policy at \$DOTS_SANDBOX_DEFAULTS ($DOTS_SANDBOX_DEFAULTS) is missing or invalid (see the diagnostic above); refusing to run '${appId}' rather than running it unconfined" >&2
                exit 1
              fi

              # cdRepoRoot (above) walks upward from $PWD for flake.nix so
              # every app works from any subdirectory; the repo-read/
              # repo-write capability then binds that same path into the
              # sandbox at the identical path (systemd-nspawn's single-
              # argument --bind=PATH form binds a host path onto itself, not
              # onto some remapped location). But the sandboxed process's
              # own working directory starts wherever systemd-nspawn
              # defaults it, which is not this path — so without resolving
              # and threading it through here, the wrapped program's OWN
              # cdRepoRoot walk (unchanged, per this task's own constraint)
              # would start from the wrong place and immediately hit its
              # "not running inside a flake checkout" exit. Resolving the
              # root out here, then `cd`-ing to that exact path with a `sh
              # -c` shim as the sandboxed command instead of the real
              # program directly, is what makes the bind-in and the
              # in-sandbox walk agree on where the checkout actually is.
              #
              # That shim is invoked by its absolute store path
              # (${pkgs.runtimeShell}), not the bare name `sh`. The bwrap
              # tier has no container rootfs — bwrap_argv (rust/dots-sandbox/
              # src/argv.rs) binds only /nix/store (read-only), /proc, /dev
              # and a tmpfs $HOME, never anything under /run or /usr the
              # launcher's own PATH points at. A bare `sh` here is therefore
              # not a style choice but a bug: bwrap resolves its argv[0] with
              # execvp against that PATH, finds nothing bound there, and dies
              # with "execvp sh: No such file or directory" before the app
              # ever starts. The absolute path resolves because every app in
              # nix/data/sandbox-policy.json runs on the `bwrap` tier today,
              # and bwrap_argv binds the store unconditionally (see
              # fixed_paths::NIX_STORE's own doc comment in argv.rs) — that
              # is not true of every tier: container_argv only binds the
              # store when the nix-daemon capability resolves to allow, and
              # vm_argv never binds it explicitly at all. Re-verify this
              # reasoning before relying on it for a container- or vm-tier
              # app. It costs the closure nothing new here only because
              # writeShellApplication already pulls in runtimeShell for
              # every script's own shebang. Do not "simplify" this back to
              # a bare `sh`.
              ${cdRepoRoot}
              export DOTS_SANDBOX_REPO_ROOT="''${DOTS_SANDBOX_REPO_ROOT:-$PWD}"

              # shellcheck disable=SC2016 # single-quoted on purpose: "$1"/
              # "$@" below must reach the INNER `sh -c`, not expand here.
              #
              # The trailing bare `sh` is argv[0] for that inner shell, a
              # conventional placeholder consumed only as "$0" so that "$1"
              # lands on the repo root — never looked up against PATH, so it
              # carries none of the bug above. Left as `sh` rather than the
              # absolute path for readability; it is a label, not a command.
              exec dots-sandbox run --app "${appId}" -- \
                ${pkgs.runtimeShell} -c 'cd "$1" && shift && exec "$@"' sh \
                "$DOTS_SANDBOX_REPO_ROOT" "${app.program}" "$@"
            '';
          })
          + "/bin/${name}";
      };
in
{
  # All 8 non-exempt apps in this file carry `sandboxed = true` and route
  # through mkSandboxedApp (see its own comment for the rollout's history,
  # and `clean`'s comment below for where the rollout actually stands
  # today). This one echoes text and touches nothing, so a wrapper bug
  # here costs a confusing message at worst — about as little as an app
  # can have to lose. `appId = "default"` overrides mkShellApp's
  # `appId ? name` default:
  # this script is internally named "dots-list", but the flake attribute
  # (and therefore the policy catalog id and `nix run .#default`) is
  # "default" — the one call site in this file where those two differ.
  default = mkShellApp "dots-list" {
    sandboxed = true;
    appId = "default";
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
  #
  # NOT sandboxed. The exemption is declared in nix/data/sandbox-policy.json
  # (with its reason), not as a `sandboxed = false` here — same as
  # nix-smoke-interactive and enroll-fido. mkSandboxedApp consults the policy
  # directly, so the policy file stays the one place that says what runs
  # unconfined; see its comment above.
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
  #
  # Not sandboxed (nix/data/sandbox-policy.json): a dev shell whose whole
  # purpose is running cargo against the user's writable checkout has nothing
  # to gain from confinement, and `exec`ing an interactive shell needs the
  # real terminal.
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
  # runtimeInputs on PATH, not the caller's own environment. Under the
  # bwrap tier that matters more than usual — the ambient
  # /run/current-system/sw/bin/nix is never bound into the sandbox at all
  # (bwrap_argv, rust/dots-sandbox/src/argv.rs, binds only /nix/store,
  # /proc, /dev and a tmpfs $HOME), so without this the bare name resolves
  # to nothing and `nix: command not found` is the first line the script
  # gets past cdRepoRoot. Pinning it as a runtimeInput makes it an
  # absolute store path baked into the script's own PATH, which /nix/store
  # being bound read-only is enough to satisfy.
  nix-lint = mkShellApp "nix-lint" {
    sandboxed = true;
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

      nix flake check --no-build

      cd rust/installer-tui && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
      cd ../settings-global && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
      cd ..

      # nix flake check --no-build only evaluates derivations, so it never
      # realizes dots-skills-primer and never runs dots-skills-primer.py's
      # asserts. Building it here is the only place in this gate that does.
      nix build .#dots-skills-primer --no-link

      cd dots-sandbox && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test && cd ..
    '';
  };

  iso = mkIsoApp {
    name = "iso";
    sandboxed = true;
  };
  iso-full = mkIsoApp {
    sandboxed = true;
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
    sandboxed = true;
    # pkgs.nix — see the runtimeInputs comment on nix-lint above for why a
    # bare `nix` call needs this under the bwrap tier.
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

  # Remove local build/test leftovers (safe — all gitignored).
  #
  # All 6 non-exempt apps in this file carry `sandboxed = true` and route
  # through mkSandboxedApp (see its own comment for why the default
  # flipped to true for everyone at once, rather than staying an opt-in
  # two apps picked up one at a time): default, nix-lint, iso, iso-full,
  # nix-smoke and this one. `rm -rf` touching the wrong tree is the one
  # way this particular app could ever have anything to lose, and the
  # sandbox is precisely what bounds that:
  # the policy grants `repo-write` and nothing else, so a confused
  # invocation can still only ever reach this checkout.
  #
  # Wrapped is not the same as working. Running these apps under the
  # sandbox surfaced two bugs already fixed on this branch: a bare `sh`
  # bwrap could not resolve (1f79557), and a bare `nix` invisible on the
  # bwrap PATH (35a7484). A third stayed open by deliberate choice:
  # nix-lint, iso, iso-full and nix-smoke all shell out to `nix`, and the
  # sandboxed `nix` refuses with "experimental Nix feature 'nix-command'
  # is disabled". bwrap_argv (rust/dots-sandbox/src/argv.rs) binds no
  # /etc and replaces $HOME with a tmpfs, so the sandboxed process never
  # reaches /etc/nix/nix.conf or ~/.config/nix/nix.conf, the only places
  # this host turns on nix-command/flakes. Those four apps cannot
  # complete inside the sandbox today; run them with `DOTS_SANDBOX=0`
  # until that gap is closed. nix-smoke-interactive and enroll-fido are
  # never wrapped at all; see mkSandboxedApp's isSandboxExempt check.
  clean = mkShellApp "clean" {
    sandboxed = true;
    text = ''
      ${cdRepoRoot}
      rm -rf -- result result-* *.qcow2 vm-state-*
      echo "cleaned build + VM-test leftovers"
    '';
  };
}
