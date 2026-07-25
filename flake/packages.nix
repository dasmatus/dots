# packages.${system} — the dots-installer Rust TUI, the in-flake aipage dists,
# the two LiveISO images, the Microsoft-signed shim, the sb-tools signing
# toolbelt and the ephemeral sbctl key hierarchy.
{
  pkgs,
  aipagePackages,
  sbToolPackages,
  ...
}:
self: {
  dots-installer = pkgs.rustPlatform.buildRustPackage {
    pname = "dots-installer";
    version = "0.1.0";
    src = ../installer-tui;
    cargoLock.lockFile = ../installer-tui/Cargo.lock;
  };
  # AIPage dists (codeberg.org/dasmatus/aipage), built from a pinned fetchGit
  # source — see nix/aipage.nix. Consumed by the LibreWolf and Brave home
  # modules via specialArgs, and embedded in both ISOs so the installer
  # substitutes them from the ISO store (offline-capable).
  aipage-firefox = aipagePackages.firefox;
  aipage-chrome = aipagePackages.chrome;
  iso = self.nixosConfigurations.live-iso.config.system.build.isoImage;
  iso-full = self.nixosConfigurations.live-iso-full.config.system.build.isoImage;
  # Microsoft-signed Fedora shim for the Secure Boot ISO chain.
  shim-signed = pkgs.callPackage ../nix/shim-signed.nix { };
  # Toolbelt for scripts/sign-iso.sh + the Secure Boot smoke test (the script
  # `nix shell`s this when the tools aren't on PATH).
  sb-tools = pkgs.buildEnv {
    name = "sb-tools";
    paths = sbToolPackages;
  };
  # Fresh sbctl key hierarchy (PK/KEK/db private keys + GUID) generated per
  # ISO build and embedded on the LiveISO at /etc/dots-sbctl-keys. The
  # installer copies them onto the target's /var/lib/sbctl so the installed
  # system boots with the same keys the ISO's signed UKIs are verified
  # against — no first-boot `sbctl create-keys` needed. The private keys ARE
  # on the ISO (world-readable in the nix store); this is acceptable for an
  # installer image that is itself single-use and dd'd to removable media,
  # and it mirrors how the MOK key is handled by scripts/sign-iso.sh
  # (generated into gitignored secrets/secureboot/). Non-reproducible by
  # design (each build mints a new keypair).
  sbctl-keys = pkgs.runCommand "dots-sbctl-keys" { nativeBuildInputs = [ pkgs.sbctl ]; } ''
        mkdir -p $out
        conf=$(mktemp)
        cat > "$conf" <<EOF
    keydir: $out/keys
    guid: $out/GUID
    files_db: $out/files.json
    bundles_db: $out/bundles.json
    EOF
        sbctl --disable-landlock --config "$conf" create-keys
        chmod -R u+rwX,go+rX $out
  '';
}
