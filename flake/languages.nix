# The programming-language toolchains, as ONE devenv module.
#
# These used to be two hand-written package lists that had to be kept in step
# by hand: the Rust/C set in nix/home/base/pkgs.nix (rustc, cargo, clippy,
# rust-analyzer, cargo-expand, clang, clang-tools) and the Haskell set in
# nix/home/profiles/portable.nix (ghc, stack, cabal-install,
# haskell-language-server, hlint, fourmolu) — with `ghc` and `stack` listed in
# BOTH, and flake/devenv.nix's `languages.rust.enable` declaring a third,
# separate Rust toolchain for the dev shell. Three declarations of "which
# compilers exist here", none of them aware of the others.
#
# This file is the single declaration. It has three consumers, and the whole
# point is that they cannot drift:
#
#   - flake/devenv.nix imports it, so `nix develop` gets the toolchains.
#   - nix/home/base/pkgs.nix evaluates it standalone through
#     `devenv.lib.mkConfig` and installs the resulting `config.packages` into
#     the user profile, so the host keeps the global `cargo` / `ghc` / `clangd`
#     it has always had. That matters here: nix/home/apps/{nixvim,zed}.nix and
#     the AI harnesses find these by bare name on PATH, and a flatpak'd
#     compiler could not see the project it is asked to build — see
#     nix/home/base/pkgs.nix's header for the full "why these are not
#     flatpaks" argument.
#   - nix/packages/aipage.nix reads two toolchain PACKAGES out of the same
#     evaluation (`languages.rust.toolchainPackage` and
#     `languages.javascript.bun.package`) for its build inputs. It does not
#     install `config.packages` — a derivation wants the compilers it names,
#     not a whole environment — but the compilers it names are the ones
#     declared here.
#
# Only the three toolchains that were hand-declared are here. `languages.nix`
# is deliberately NOT enabled: it installs nixd, and this repo has settled on
# nil (nix/home/apps/zed.nix disables nixd explicitly), so nil + nixfmt stay
# declared where the editors that use them are. Same for stylua — devenv's
# `languages.lua` ships lua + lua-language-server, neither of which anything
# here wants, and a formatter alone is not a toolchain.
{ pkgs, ... }:
{
  # rustc, cargo, clippy, rustfmt and rust-analyzer, joined into one toolchain
  # package, plus RUST_SRC_PATH and the clang linker driver.
  languages.rust.enable = true;

  # `lsp.package` would add a SECOND rust-analyzer beside the one that is
  # already a toolchain component. Harmless on a devShell PATH, but the home
  # profile is a buildEnv, where two different store paths both offering
  # bin/rust-analyzer are a collision. The component is the one that stays.
  languages.rust.lsp.enable = false;

  # Enabled implicitly by languages.rust (it wants `cc` for linking); stated
  # outright because this repo installs the C toolchain on its own account —
  # clangd is what nix/home/ai/claude.nix's clangd-lsp plugin spawns by bare
  # name, and what both editors are configured against.
  languages.c.enable = true;
  languages.cplusplus.enable = true;

  # Both C modules default their LSP to ccls. clang-tools (clangd,
  # clang-format, clang-tidy) comes with them either way and IS the server
  # both editors are pointed at, so ccls would be a second, unused C language
  # server in the profile.
  languages.c.lsp.enable = false;
  languages.cplusplus.lsp.enable = false;

  # ghc, cabal-install, hpack, zlib and a `stack` wrapped with
  # `--no-nix --system-ghc --no-install-ghc`, so stack builds against the GHC
  # in this profile instead of trying to provision its own (ghcup is not
  # installable on NixOS — nixpkgs throws "no compatible bindist" — which is
  # why the pure-nixpkgs route was the only reproducible one to begin with).
  languages.haskell.enable = true;

  # devenv's default is `haskell-language-server.override { supportedGhcVersions
  # = [ <this ghc> ]; }`. That override is not what Hydra builds, so it is not
  # in the binary cache and compiles HLS from source — too heavy for a repo
  # that is rebuilt as often as this one and for CI. The plain package is the
  # multi-GHC WRAPPER; its default build ships the variant for the default ghc
  # (Stackage LTS 24), which is the case that has to work out of the box. For
  # a project on an older LTS, add a per-project devshell with the matching
  # haskell.packages.ghcXX.haskell-language-server; both editors pick it up
  # through `nix develop` / direnv.
  languages.haskell.lsp.package = pkgs.haskell-language-server;

  # Bun. There is no JavaScript in THIS repo — the consumer is
  # nix/packages/aipage.nix, which builds the AIPage extension's CSS step with
  # `bunx postcss` and installs its JS deps through bun2nix's hook. Declaring
  # it here rather than reaching for `pkgs.bun` there means the bun that
  # builds aipage, the bun in `nix develop`, and the bun on the machine's PATH
  # are one package by construction.
  languages.javascript.enable = true;
  languages.javascript.bun.enable = true;

  # Bun instead of Node, not Bun as well as Node — the same stance the
  # `claude-dev` script in flake/devenv.nix states outright ("Always use Bun
  # instead of Node.js for running scripts, installing packages, and executing
  # JavaScript or TypeScript"). Nothing here has ever had `node` on PATH and
  # this is not the change that should quietly add it.
  languages.javascript.nodejs.enable = false;

  # Forced by the above, not a separate judgement: devenv asserts
  # `lsp.enable -> nodejs.enable`, since typescript-language-server runs on
  # Node. No editor loses anything — nixvim installs its own copy for
  # `lsp.servers.ts_ls` (nix/home/apps/nixvim.nix) and Zed's TypeScript
  # servers are built in.
  languages.javascript.lsp.enable = false;

  # `bun.install.enable` stays off (its default). It would run `bun install`
  # in `enterShell` against the devenv root, and this repo has no package.json
  # at its root — every `nix develop` would open with "No package.json found".
  # aipage's own deps are vendored by bun2nix inside the derivation, which is
  # where they belong.

  # The three tools no devenv language module carries, kept because they were
  # in the lists this file replaces. `packages` is devenv's own escape hatch,
  # so they ride along into both consumers exactly like everything above.
  packages = with pkgs; [
    cargo-expand
    hlint
    fourmolu
  ];
}
