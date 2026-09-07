# Builds the AIPage browser extension (codeberg.org/dasmatus/aipage) from a
# pinned `main` source rev and produces the unpacked `dist-firefox` /
# `dist-chrome` store dirs that nix/home/{librewolf,brave}.nix consume.
#
# Why fetchgit + an in-flake build (not a flake input, not the old local
# tarball): aipage's own flake only exposes an *impure* `apps.build` (it shells
# out to `bun install` + `bunx`), and its built `dist-*` dirs are gitignored —
# so no flake input can reach a built artifact. `pkgs.fetchgit` with a pinned
# `rev` + `hash` is a content-addressed fixed-output DERIVATION: pure under
# `nix flake check`, baked into the ISO closure at build time, and substituted
# from the install medium's store at install time (no network, no source build
# at install time). Crucially it is a derivation, not the `builtins.fetchGit`
# primitive: its output store path is determined by `hash` alone, so evaluating
# it never fetches (a derivation's .outPath is computed from the hash without
# realizing it). `builtins.fetchGit`, by contrast, is an eval-time primitive
# that resolves its output through the nix fetcher cache (~/.cache/nix) — empty
# on a fresh install medium / VM, so an offline `nixos-install --flake` would
# shell out to `git` to rediscover the path. fetchgit sidesteps that entirely,
# which is what makes the offline VM install test (tests/default.nix,
# `limine-install-boot`) and a truly offline real install work. The old design
# used a `file://$HOME/.local/share/aipage/dist-firefox.tar` FOD that only
# existed on the dev machine, so `nixos-install` on the ISO failed to evaluate.
#
# The build re-implements aipage's `xtask build` pipeline (xtask/src/main.rs)
# in bash rather than running `cargo run -p xtask`: it gives hard failures on
# missing tools (xtask silently skips CSS/wasm-opt), writes directly to `$out`
# (xtask writes into the read-only workspace root), and skips compiling xtask.
# Keep this in step with xtask when aipage's pipeline changes; the update
# script (scripts/update-aipage.sh) warns on xtask drift.
#
# Toolchain: cargo/rustc and bun are NOT picked out of `pkgs` here — they come
# from flake/languages.nix through `devenv.lib.mkConfig`, so this build, the
# dev shell and the user profile compile with one declared toolchain. See the
# `toolchains` binding below.
#
# Vendoring: cargo deps via `rustPlatform.fetchCargoVendor` (Cargo.lock is v4,
# no git deps — only intra-workspace path deps, which live in `aipageSrc` and
# are found via the workspace layout by `cargoSetupHook`); JS deps
# (postcss/tailwind/autoprefixer) via bun2nix's `fetchBunDeps` + `hook`, which
# populates `node_modules` offline from a nix-store cache. `sass` uses
# `pkgs.dart-sass` directly (the `sass` npm package pulls `sass-embedded`,
# which fetches a native binary in a postinstall — avoided).
{
  pkgs,
  rustPlatform,
  inputs,
}:
let
  # The Rust and Bun toolchains this build compiles with, read out of
  # flake/languages.nix — the same devenv module `nix develop` imports and
  # nix/home/base/pkgs.nix installs into the user profile. Before this, the
  # build named `pkgs.cargo`, `pkgs.rustc` and `pkgs.bun` directly, which meant
  # aipage could silently be built by a different Rust than the one the repo
  # declares for everything else.
  #
  # Only two PACKAGES are taken, not devenv's `config.packages`: a derivation
  # wants the compilers it names in `nativeBuildInputs`, not a whole
  # environment. `mkConfig` is module-system evaluation only — no shell is
  # built and no assertion in that file is forced.
  #
  # `pkgs` here is flake/lib.nix's `pkgsBun` (the bun2nix-overlaid instance),
  # so `bun` and the Rust toolchain come from the very instance the rest of
  # this derivation is built against.
  toolchains = inputs.devenv.lib.mkConfig {
    inherit pkgs inputs;
    modules = [ ../../flake/languages.nix ];
  };

  # `toolchainPackage` (rustc + cargo + clippy + rustfmt + rust-analyzer joined
  # into one package), not the individual `toolchain.cargo` / `toolchain.rustc`
  # attributes. Those two only track nixpkgs; `toolchainPackage` is the
  # attribute that also follows a `languages.rust.channel` switch to a
  # rust-overlay stable/nightly, which is exactly the change that must not
  # leave this build on a different compiler from the dev shell.
  rustToolchain = toolchains.languages.rust.toolchainPackage;
  bun = toolchains.languages.javascript.bun.package;
  # Pin: codeberg.org/dasmatus/aipage main. Bump via scripts/update-aipage.sh.
  # `hash` is the narHash of the fetched tree (refreshed by the update script's
  # fakeHash→build→mismatch loop, same as the fetchCargoVendor hash below).
  aipageRev = "944064e01a58f9f9e0c0e76c91aea17f6ce269b1";
  aipageSrc = pkgs.fetchgit {
    url = "https://codeberg.org/dasmatus/aipage.git";
    rev = aipageRev;
    hash = "sha256-Qz05M3hCsLG2eeYS1qoOktS+LSBwG9EilvoitOUyvGk=";
  };

  # Workspace version (manifests share it). Pure-eval readFile of a fetchGit
  # store path is allowed (it's a store path, not a mutable local path input).
  aipageVersion =
    (builtins.fromTOML (builtins.readFile "${aipageSrc}/Cargo.toml")).workspace.package.version;

  # wasm-bindgen-cli's version MUST exactly equal the `wasm-bindgen` crate
  # resolved in aipage's Cargo.lock (currently 0.2.125): the CLI refuses to
  # process a .wasm built with a different crate version. nixpkgs ships an
  # older CLI, so build the matched one from fetchCrate (recipe + hashes
  # reused from aipage's own flake.nix). The update script asserts the lock
  # version still matches.
  wasmBindgenVersion = "0.2.125";
  wasm-bindgen-cli = pkgs.rustPlatform.buildRustPackage {
    pname = "wasm-bindgen-cli";
    version = wasmBindgenVersion;
    src = pkgs.fetchCrate {
      pname = "wasm-bindgen-cli";
      version = wasmBindgenVersion;
      hash = "sha256-zRawtjxMOdTMX+mZaiNR3YYfTiZJhf9qj7kXSSeMxrc=";
    };
    cargoHash = "sha256-aZCfgR23Qb0Pn4Mm4ToMtuuRQqSJjXCR9li/VvP5CTM=";
    doCheck = false;
    nativeBuildInputs = [ pkgs.gcc ];
  };

  # Vendored registry crates for the whole workspace (sidebar/background/
  # content + their shared crates + xtask). Intra-workspace path deps are part
  # of `aipageSrc` and are NOT re-vendored. `hash` is refreshed by the update
  # script via the lib.fakeHash → "got:" sha256 loop.
  cargoDeps = rustPlatform.fetchCargoVendor {
    src = aipageSrc;
    hash = "sha256-f0S2yAu9pn/sjpZECbo8G4tTIRDDKz3jfiyWH9BC3ek=";
  };

  # Vendored JS deps for the CSS step (postcss-cli + tailwind + autoprefixer).
  # `bun.nix` is generated by `bun2nix -l bun.lock -o nix/packages/aipage-bun.nix` and
  # carries the per-package fetchurl hashes from aipage's bun.lock, so
  # `fetchBunDeps` takes no `hash` argument here.
  #
  # `nix/packages/aipage-bun.nix` stays a tracked file despite being generated. A
  # git-based flake (`git+file://…` or a plain checkout) only ever evaluates
  # tracked files, and `fetchBunDeps` reads each package's hash straight out
  # of this file at eval time rather than through any flake input, so an
  # untracked or gitignored copy makes the flake fail to evaluate the moment
  # it isn't sitting on disk from some other build. That happened once
  # already: the file was gitignored and deleted, which broke evaluation
  # outright.
  #
  # When restoring it, take it from git history rather than rerunning
  # `bun2nix -l bun.lock -o nix/packages/aipage-bun.nix`. A regeneration is exactly
  # what caused the second incident here: it silently dropped two of the
  # 554 entries down to `hash = ""`, a value `fetchurl` accepts and
  # normalises to the all-zero fixed-output hash. Nothing about that is
  # loud — eval passes, `nix build --dry-run` passes, even `.drvPath` on the
  # packages that pull those two deps in stays a well-formed string — the
  # failure only surfaces at realization time, after downloading the real
  # tarball, as a hash mismatch that names the single npm package and
  # nothing about this file. `aipage-bun-hashes-eval` in flake/checks.nix
  # catches both that and a hash baked in as the literal all-zero value,
  # at eval time, so this can't recur silently.
  bunDeps = pkgs.bun2nix.fetchBunDeps { bunNix = ./aipage-bun.nix; };

  # The target-shared dist: 3 wasm bundles (bindgen + wasm-opt) + CSS + static
  # assets. Built once; the per-target wrappers below copy this and add the
  # target manifest, so the wasm isn't built twice.
  aipageDistCommon = pkgs.stdenv.mkDerivation {
    pname = "aipage-dist-common";
    version = aipageVersion;
    src = aipageSrc;

    nativeBuildInputs = [
      rustToolchain
      rustPlatform.cargoSetupHook
      pkgs.llvmPackages.lld # wasm32-unknown-unknown linker (nixpkgs rustc
      # delegates wasm linking to the system `lld`, not a self-contained
      # rust-lld — without this, `cargo build --target wasm32-…` fails with
      # "linker `lld` not found").
      wasm-bindgen-cli
      pkgs.binaryen # `wasm-opt`
      bun
      pkgs.bun2nix.hook # reads `bunDeps`, populates node_modules offline
      pkgs.dart-sass # `sass` binary — replaces `bunx sass`
    ];

    inherit cargoDeps bunDeps;

    # `--backend=copyfile`, not bun's default `hardlink`. bun2nix's hook seeds
    # BUN_INSTALL_CACHE_DIR with `cp -r` (no `-L`, despite its own comment
    # claiming otherwise), so all 541 cache entries stay *symlinks* into
    # per-package `bun-pkg-…` store paths. bun then hardlinks each package's
    # files through those symlinks — i.e. link(2) whose resolved source is a
    # root-owned, read-only /nix/store file. Linux refuses that with EPERM
    # whenever `fs.protected_hardlinks=1` (the systemd default, so: Fedora and
    # NixOS both) and the builder is neither the file's owner nor holds write
    # access to it, and the install dies with 541 × "EPERM: Operation not
    # permitted: failed to link package". Copying sidesteps store ownership
    # entirely, and touches only the packages actually installed.
    #
    # Setting this *replaces* the hook's default flag array rather than
    # appending to it, so `--linker=isolated` has to be repeated. And it has to
    # be `bunInstallFlags`, not `bunInstallFlagsArray`: the latter would need
    # `__structuredAttrs`; without it the list
    # arrives as one space-joined string and `concatTo` passes it through as a
    # single escaped argv entry. The plain `…Flags` string is word-split.
    bunInstallFlags = "--linker=isolated --backend=copyfile";

    # Point the wasm32 target at the nix-store lld explicitly (belt-and-
    # suspenders alongside lld being on PATH via nativeBuildInputs).
    CARGO_TARGET_WASM32_UNKNOWN_UNKNOWN_LINKER = "${pkgs.llvmPackages.lld}/bin/lld";

    # Mirrors xtask's `build(target)`: cargo build the 3 wasm crates →
    # wasm-bindgen each (sidebar=web ES module, background/content=no-modules)
    # → wasm-opt -Oz -all → CSS → copy the shared static assets. The
    # per-target manifest is added by `mkTarget`.
    buildPhase = ''
      runHook preBuild

      mkdir -p "$out"

      cargo build --release --target wasm32-unknown-unknown \
        -p aipage-sidebar -p aipage-background -p aipage-content

      for c in sidebar background content; do
        case "$c" in
          sidebar) bt=web ;;
          *) bt=no-modules ;;
        esac
        wasm-bindgen \
          "target/wasm32-unknown-unknown/release/aipage_$c.wasm" \
          --out-dir "$out" --out-name "$c" --target "$bt" --no-typescript
        wasm-opt -Oz -all "$out/''${c}_bg.wasm" -o "$out/''${c}_bg.wasm"
      done

      sass assets/sidebar.scss "$out/sidebar.css" --style=compressed --no-source-map
      bunx postcss assets/tailwind.css -o "$out/tailwind.css"

      cp assets/sidebar.html assets/sidebar_loader.js \
         assets/background_loader.js assets/content_loader.js \
         assets/anti_cheat.js "$out/"

      runHook postBuild
    '';

    dontInstall = true; # buildPhase writes directly to $out
  };

  # Per-target wrapper: the shared dist + the target manifest as manifest.json.
  # `passthru.manifest` exposes the parsed manifest at eval time so consumers
  # can derive the gecko id / version without hardcoding (and without a build).
  mkTarget =
    target: manifestFile:
    pkgs.runCommand "aipage-${target}-${aipageVersion}"
      {
        passthru = {
          inherit aipageSrc aipageVersion;
          manifest = builtins.fromJSON (builtins.readFile "${aipageSrc}/assets/${manifestFile}");
        };
      }
      ''
        mkdir -p "$out"
        cp -r "${aipageDistCommon}/." "$out/"
        cp "${aipageSrc}/assets/${manifestFile}" "$out/manifest.json"
      '';
in
{
  firefox = mkTarget "firefox" "manifest.firefox.json";
  chrome = mkTarget "chrome" "manifest.chrome.json";
}
