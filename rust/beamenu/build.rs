//! Locate the patched `libbemenu` that `beamenu` links against.
//!
//! The library comes from the `beamenu-view` derivation (flake/packages.nix),
//! which is stock bemenu plus `nix/patches/beamenu/*`. It installs a normal
//! `bemenu.pc`, so pkg-config resolves both the link flag and the include
//! path; nothing here is Nix-specific beyond that store path being on
//! `PKG_CONFIG_PATH`, which the derivation's `buildInputs` arranges.

fn main() {
    println!("cargo:rerun-if-changed=build.rs");

    if let Err(err) = pkg_config::Config::new()
        .atleast_version("0.6.23")
        .probe("bemenu")
    {
        // A plain `cargo build` outside the Nix build environment has no
        // beamenu-view on PKG_CONFIG_PATH. Fall back to a bare link flag so
        // `cargo check`/`cargo test` still work on the pure-Rust modules,
        // which is where every unit test lives.
        println!(
            "cargo:warning=pkg-config could not find bemenu ({err}); falling back to -lbemenu"
        );
        println!("cargo:rustc-link-lib=dylib=bemenu");
    }
}
