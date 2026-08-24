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

  # The patched libbemenu, for the crates and gates that link against it.
  beamenuView = self.packages.${pkgs.stdenv.hostPlatform.system}.beamenu-view;

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
    ];
    text = ''
      ${cdRepoRoot}
      nix flake check --no-build
      cd rust/installer-tui && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
      cd ../wallpaper-tui && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
      cd ../hyprmon && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
      cd ../settings-global && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
      # beamenu links the patched libbemenu, so its build.rs needs beamenu-view
      # on PKG_CONFIG_PATH; without it build.rs falls back to a bare -lbemenu
      # and the test binaries fail to link.
      cd ../beamenu
      PKG_CONFIG_PATH="${beamenuView}/lib/pkgconfig" \
      LD_LIBRARY_PATH="${beamenuView}/lib" \
        sh -c 'cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test'
      cd ../beamenu-canvas && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
      cd ../beamenu-calc && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
      cd ../beamenu-status && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
      cd ../dots-osd && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
    '';
  };

  # Sanitizer gate for the one C++ translation unit 06-filter-pills.patch adds
  # to bemenu: lib/renderers/pills.cpp, the pill bar's scroll geometry. It is
  # pure arithmetic over a width array, which is what makes it worth testing on
  # its own and what lets this run with no compositor.
  #
  # The driver lives in nix/patches/beamenu/tests/ rather than inside the patch
  # so the series keeps one less hunk to rebase onto upstream bemenu. Applying
  # the series here rather than reusing the beamenu-view derivation is
  # deliberate too: this has to fail loudly when a patch stops applying.
  beamenu-patch-test = mkShellApp "beamenu-patch-test" {
    runtimeInputs = [
      pkgs.clang
      pkgs.patch
    ];
    text = ''
      ${cdRepoRoot}
      work="$(mktemp -d)"
      trap 'rm -rf "$work"' EXIT

      cp -r ${pkgs.bemenu.src} "$work/src"
      chmod -R u+w "$work/src"
      for p in nix/patches/beamenu/0*.patch; do
        echo "applying $(basename "$p")"
        patch -d "$work/src" -p1 -s < "$p"
      done

      clang++ -std=c++23 -g -O1 -fsanitize=address,undefined -fno-omit-frame-pointer \
        -I"$work/src/lib" \
        nix/patches/beamenu/tests/pills_scroll_test.cpp \
        "$work/src/lib/renderers/pills.cpp" \
        -o "$work/pills_scroll_test"

      clang++ -std=c++23 -g -O1 -fsanitize=address,undefined -fno-omit-frame-pointer \
        -I"$work/src/lib" \
        nix/patches/beamenu/tests/rows_fit_test.cpp \
        "$work/src/lib/renderers/rows.cpp" \
        -o "$work/rows_fit_test"

      # The units under test allocate nothing, so leak detection buys nothing
      # here, and LeakSanitizer needs ptrace, which sandboxes tend to refuse.
      ASAN_OPTIONS=detect_leaks=0 \
      UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=1 \
        "$work/pills_scroll_test"

      ASAN_OPTIONS=detect_leaks=0 \
      UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=1 \
        "$work/rows_fit_test"
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
