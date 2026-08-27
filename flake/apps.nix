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
  # nix/home/quickshell/qml because Theme.qml is generated from
  # rust/palette.json and only exists in the built tree.
  quickshellConfig = self.packages.${pkgs.stdenv.hostPlatform.system}.quickshell-config;

  # Build a LiveISO closure into result-iso. Plain (unsigned) — Secure Boot
  # was removed; the ISO boots through plain OVMF / firmware defaults. The
  # installed system uses systemd-boot + TPM2 auto-unlock (no UKI signing).
  mkIsoApp =
    {
      name,
      target ? "iso",
    }:
    {
      type = "app";
      program =
        (pkgs.writeShellApplication {
          inherit name;
          text = ''
            ${cdRepoRoot}
            nix build .#${target} -o result-iso
          '';
        })
        + "/bin/${name}";
    };

  # Sugar: wrap a writeShellApplication into an app attrset.
  mkShellApp = name: args: {
    type = "app";
    program = (pkgs.writeShellApplication (args // { inherit name; })) + "/bin/${name}";
  };
in
{
  default = mkShellApp "dots-list" {
    text = ''
      ${cdRepoRoot}
      echo "tokyonight-dots — nix run .#<app>"
      echo
      echo "  nix-lint               flake eval + cargo fmt/clippy/test for every crate"
      echo "  iso                    build the LiveISO (plain, unsigned)"
      echo "  iso-full               same, with intel+amd system closures embedded"
      echo "  nix-smoke              NixOS VM test: boot the LiveISO under OVMF+TPM2"
      echo "  nix-smoke-interactive  test driver Python REPL"
      echo "  enroll-fido            enroll a FIDO2/U2F key as a mandatory 2FA factor"
      echo "  memory-derive          rebuild the agentmem 'derived' graph from this checkout"
      echo "  memory-health          check agentmem's reads-vs-writes kill criterion (design spec section 10)"
      echo "  clean                  remove local build/test leftovers"
    '';
  };

  # Static gate: flake eval (--no-build), then fmt/clippy/test for every Rust
  # crate in the repo. Cargo is pinned in runtimeInputs so the dev shell need
  # not be on.
  nix-lint = mkShellApp "nix-lint" {
    runtimeInputs = [
      pkgs.cargo
      pkgs.rustc
      pkgs.rustfmt
      pkgs.clippy
      pkgs.qt6.qtdeclarative
      pkgs.findutils
    ];
    text = ''
      ${cdRepoRoot}

      # qmllint over the shell's QML, before the flake eval because it is the
      # cheaper gate and because `nix flake check` cannot run on a bare
      # checkout at all: nix/settings.nix is a symlink into /var/lib/dots,
      # which pure eval refuses and CI works around by materialising a stub.
      # Ordering it second would mean the QML is never linted locally.
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
      find "${quickshellConfig}" -name '*.qml' -print0 | xargs -0 -r qmllint \
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
      QT_QPA_PLATFORM=offscreen qmltestrunner \
        -import "${pkgs.qt6.qtdeclarative}/lib/qt-6/qml" \
        -input tests/qml

      nix flake check --no-build

      cd rust/installer-tui && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
      cd ../wallpaper-tui && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
      cd ../hyprmon && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
      cd ../settings-global && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
      cd ..

      # pg_agentmem builds through buildPgrxExtension rather than plain
      # cargo: it links against real PostgreSQL headers via bindgen.
      # `cargo fmt --check` still runs directly (no server needed); the
      # actual build gate is the flake package. Its #[pg_test] assertions
      # (rust/pg-agentmem/tests/) are not part of this gate: `cargo pgrx
      # test`'s own install step writes into postgresql.pg_config's
      # reported --sharedir/--pkglibdir, which for a nixpkgs postgresql
      # package is the immutable store output, so doCheck is false here —
      # see flake/packages.nix for the same reasoning every other pgrx
      # extension in nixpkgs already relies on.
      cd pg-agentmem && cargo fmt --check && cd ..
      nix build .#pg-agentmem --no-link

      cd dots-memory-mcp && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test && cd ..

      cd dots-memory-derive && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test && cd ..
    '';
  };

  # Rebuild the `origin = 'derived'` half of the agentmem graph (design spec
  # section 7, plan 5): the extractor prints Mermaid over this checkout's own
  # structure, and agentmem.rebuild_derived swaps the `dots` scope's whole
  # derived slice for it in one transaction, stamped with the commit read.
  # Peer auth maps the OS user to both the database and role of the same
  # name (agentmem.nix), so no connection string is needed beyond -U/-d.
  #
  # The call goes through a scratch -f script rather than -c: psql only
  # performs :'var' interpolation when reading a script file (-f or
  # interactive), never in -c's single-command mode, so a -c call with the
  # Mermaid document spliced in by hand would need to hand-escape every
  # quote in it instead of letting psql do that correctly.
  memory-derive = mkShellApp "memory-derive" {
    runtimeInputs = [
      pkgs.postgresql_18
      self.packages.${pkgs.stdenv.hostPlatform.system}.dots-memory-derive
    ];
    text = ''
      ${cdRepoRoot}
      sha="$(git rev-parse HEAD)"
      doc="$(dots-memory-derive .)"
      db="$(id -un)"
      script="$(mktemp)"
      trap 'rm -f "$script"' EXIT
      echo "SELECT agentmem.rebuild_derived('dots', :'doc', :'sha');" > "$script"
      count="$(psql -U "$db" -d "$db" -v ON_ERROR_STOP=1 -v doc="$doc" -v sha="$sha" \
        -tAf "$script")"
      echo "rebuilt the derived graph: $count edges"
    '';
  };

  # Render agentmem.health() (migration 0005) for a human, checking the kill
  # criterion committed to in design spec section 10: this store gets deleted
  # rather than tuned if reads never exceed writes within a month of the
  # first stored row. Peer auth maps the OS user to both the database and
  # role of the same name (agentmem.nix), so -U/-d is all a connection needs.
  #
  # -Atc emits one unaligned, unheaded row of '|'-joined columns — the
  # verdict text itself never contains that character — and the shell read
  # below splits it back out into a small report instead of a raw psql table.
  memory-health = mkShellApp "memory-health" {
    runtimeInputs = [ pkgs.postgresql_18 ];
    text = ''
      ${cdRepoRoot}
      db="$(id -un)"
      row="$(psql -U "$db" -d "$db" -v ON_ERROR_STOP=1 -Atc "
        SELECT reads || '|' || writes || '|' || coalesce(ratio::text, 'n/a')
          || '|' || coalesce(oldest_fact_age::text, 'n/a')
          || '|' || live_facts || '|' || superseded_facts || '|' || stale_facts
          || '|' || verdict
        FROM agentmem.health();
      ")"
      IFS='|' read -r reads writes ratio age live superseded stale verdict <<< "$row"
      echo "agentmem health (last 30 days)"
      echo "  reads:            $reads"
      echo "  writes:           $writes"
      echo "  reads/writes:     $ratio"
      echo "  oldest fact age:  $age"
      echo "  live facts:       $live"
      echo "  superseded facts: $superseded"
      echo "  stale facts:      $stale"
      echo
      echo "  verdict: $verdict"
    '';
  };

  iso = mkIsoApp { name = "iso"; };
  iso-full = mkIsoApp {
    name = "iso-full";
    target = "iso-full";
  };

  # Boot the ISO under OVMF + TPM2 (NixOS VM test). Pass args via
  # `nix run .#nix-smoke -- …`.
  nix-smoke = mkShellApp "nix-smoke" {
    text = ''
      ${cdRepoRoot}
      nix build -L ".#checks.x86_64-linux.iso-boot" "$@"
    '';
  };

  # Debug the ISO boot test in the driver's interactive Python REPL
  # (.#checks.x86_64-linux.iso-boot.driverInteractive).
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
  clean = mkShellApp "clean" {
    text = ''
      ${cdRepoRoot}
      rm -rf result result-* *.qcow2 vm-state-*
      echo "cleaned build + VM-test leftovers"
    '';
  };
}
