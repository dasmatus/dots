# devShells.${system} — the dev shell for hacking on the two Rust crates
# (installer-tui and wallpaper-tui): a plain Rust toolchain so
# `cargo fmt`/`cargo clippy`/`cargo test`/`cargo run` work locally without a
# system rust install. Both are pure TUIs with no native deps, so no
# pkg-config / webkit / gtk stack is needed here (the old Tauri dev shell
# carried it).
{ pkgs }:
{
  default = pkgs.mkShell {
    nativeBuildInputs = [
      pkgs.cargo
      pkgs.rustc
      pkgs.rustfmt
      pkgs.clippy
    ];
    RUST_SRC_PATH = pkgs.rustPlatform.rustLibSrc;
  };
}
