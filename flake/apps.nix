# apps.${system} — the retired Justfile, now nix-native. Each app is a pinned
# shell script (pkgs.writeShellApplication); run with `nix run .#<name>` (or
# `nix run .` for the default = recipe list). `cdRepoRoot` makes them work
# from any subdir — `nix run` doesn't auto-cd to the flake root the way `just`
# did, and cargo + the signing script need the user's writable checkout, not
# the read-only flake store path.
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
  signScript = "${self}/scripts/sign-iso.sh";

  # Build the LiveISO and (unless `sign = false`) rewrite its EFI chain via
  # scripts/sign-iso.sh. The script is taken from the flake's own store path
  # so the app runs from any cwd; the MOK keydir and the signed-output path
  # are pinned to the repo root so the persistent `secrets/secureboot/` key
  # keeps being reused across builds.
  mkIsoApp =
    {
      name,
      target ? "iso",
      sign ? true,
      sbctl ? false,
    }:
    {
      type = "app";
      program =
        (pkgs.writeShellApplication {
          inherit name;
          text = ''
            ${cdRepoRoot}
            nix build .#${target} -o result-iso
          ''
          + lib.optionalString sign ''
            isos=( result-iso/iso/*.iso )
            iso="''${isos[0]}"
            base="$(basename "$iso" .iso)"
            ${signScript} \
              -k secrets/secureboot \
              -o "result-iso-signed/''${base}-signed.iso" \
              ${lib.optionalString sbctl "--sbctl "}\
              "$iso"
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
      echo "  nix-lint               flake eval + cargo fmt/clippy/test (both Rust crates)"
      echo "  iso                    build + Secure Boot-sign the LiveISO (the default)"
      echo "  iso-full               same, with intel+amd system closures embedded"
      echo "  iso-unsigned           plain unsigned LiveISO (no signing keys touched)"
      echo "  iso-cosign             sign + cosign GRUB/kernels with the local sbctl db key"
      echo "  iso-signed             deprecated alias for iso"
      echo "  nix-smoke              NixOS VM test: boot the signed ISO under Secure-Boot-enforcing OVMF+TPM2"
      echo "  nix-smoke-interactive  test driver Python REPL (Secure Boot variant)"
      echo "  enroll-fido            enroll a FIDO2/U2F key as a mandatory 2FA factor"
      echo "  clean                  remove local build/test leftovers"
    '';
  };

  # Static gate: flake eval (--no-build) + fmt/clippy/tests for both Rust
  # crates. Cargo is pinned in runtimeInputs so the dev shell need not be on.
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
      cd installer-tui && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
      cd ../wallpaper-tui && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
    '';
  };

  iso = mkIsoApp { name = "iso"; };
  iso-full = mkIsoApp {
    name = "iso-full";
    target = "iso-full";
  };
  iso-unsigned = mkIsoApp {
    name = "iso-unsigned";
    sign = false;
  };
  iso-cosign = mkIsoApp {
    name = "iso-cosign";
    sbctl = true;
  };
  # Deprecated alias — signing is the default now.
  iso-signed = mkIsoApp { name = "iso-signed"; };

  # Boot the signed ISO under Secure Boot-ENFORCING OVMF + TPM2 (NixOS VM
  # test). `--no-secure-boot` runs the plain unsigned check (DOTS_TUI_READY
  # only). Pass args via `nix run .#nix-smoke -- …`.
  nix-smoke = mkShellApp "nix-smoke" {
    text = ''
      ${cdRepoRoot}
      check=iso-secureboot
      for a in "$@"; do
        if [[ "$a" == "--no-secure-boot" ]]; then
          check=iso-boot
        fi
      done
      nix build -L ".#checks.x86_64-linux.$check"
    '';
  };

  # Debug the Secure Boot VM test in the driver's interactive Python REPL
  # (plain variant: .#checks.x86_64-linux.iso-boot.driverInteractive).
  nix-smoke-interactive = mkShellApp "nix-smoke-interactive" {
    text = ''
      ${cdRepoRoot}
      nix run .#checks.x86_64-linux.iso-secureboot.driverInteractive
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
