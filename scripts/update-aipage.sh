#!/usr/bin/env bash
# Bump the pinned AIPage (codeberg.org/dasmatus/aipage) source rev, regenerate
# the vendored JS-deps lock (nix/packages/aipage-bun.nix), refresh the fetchCargoVendor
# FOD hash, and verify the in-flake build (nix/packages/aipage.nix →
# packages.aipage-{firefox,chrome}).
#
# Run on the dev machine (network needed the first time: fetchGit clones
# codeberg, fetchCargoVendor/fetchBunDeps fetch crates/npm tarballs). Then:
#   git commit nix/packages/aipage.nix nix/packages/aipage-bun.nix flake.lock
#   sudo nixos-rebuild switch --flake .#tokyonight   (or rebuild the ISO)
#
# This replaces the old flow that built dist-* tarballs into
# ~/.local/share/aipage/ and grepped narHashes into nix/home/{brave,librewolf}.nix.
# The dist is now built inside the dots flake, so there's nothing local to
# refresh per machine.
set -euo pipefail

AIPAGE=${AIPAGE:-$HOME/Dokumente/codeberg/personal/aipage}
DOTS=${DOTS:-$HOME/Dokumente/codeberg/personal/dots}
BUN2NIX="github:nix-community/bun2nix#default"
# The wasm-bindgen-cli version pinned in nix/packages/aipage.nix; must equal the
# `wasm-bindgen` crate resolved in aipage's Cargo.lock. Bumped manually here
# AND in nix/packages/aipage.nix (wasmBindgenVersion + the fetchCrate/cargoHash) when
# aipage upgrades wasm-bindgen.
EXPECT_WASM_BINDGEN="0.2.125"

cd "$AIPAGE"
git switch main
git pull --ff-only
# Pin only a clean published main. A dirty tree would pin uncommitted state.
[ -z "$(git status --porcelain --untracked=no)" ] || {
  echo "aipage: working tree dirty on main; commit/stash first" >&2
  exit 1
}
rev=$(git rev-parse HEAD)
echo "[aipage] pinning main rev $rev"

# Refuse to pin a rev whose Cargo.lock's wasm-bindgen != the CLI we build,
# else wasm-bindgen refuses to process the .wasm at build time.
lock_wb=$(grep -A1 'name = "wasm-bindgen"' Cargo.lock | grep '^version' | head -1 | awk '{print $3}')
[ "$lock_wb" = "$EXPECT_WASM_BINDGEN" ] || {
  cat >&2 <<EOF
aipage: Cargo.lock wasm-bindgen=$lock_wb but nix/packages/aipage.nix builds CLI $EXPECT_WASM_BINDGEN.
Bump wasmBindgenVersion + the fetchCrate \`hash\` + \`cargoHash\` in nix/packages/aipage.nix
(reuse the values from aipage's own flake.nix), then re-run.
EOF
  exit 1
}

cd "$DOTS"
# 1. Regenerate the JS-deps lock from aipage's bun.lock at this rev.
echo "[aipage] regenerating nix/packages/aipage-bun.nix (bun2nix)…"
nix run "$BUN2NIX" -- -l "$AIPAGE/bun.lock" -o nix/packages/aipage-bun.nix

# 2. Update the pinned rev in nix/packages/aipage.nix.
perl -0pi -e 's/aipageRev = "[0-9a-f]{40}";/aipageRev = "'"$rev"'";/' nix/packages/aipage.nix

# 3. Refresh the aipageSrc fetchgit hash: reset it to lib.fakeHash, build, and
#    paste the "got: sha256-…" from the mismatch error back in. MUST run before
#    the fetchCargoVendor refresh (step 4): cargoDeps takes `src = aipageSrc`,
#    so a stale/wrong aipageSrc hash surfaces first and would mask the
#    cargoDeps mismatch. fetchBunDeps per-package hashes come from
#    aipage-bun.nix, and the wasm-bindgen-cli hashes only change when the crate
#    version bumps (step 2 guards that). If the verify build in step 5 still
#    surfaces a *different* FOD mismatch, fix it by hand.
echo "[aipage] refreshing aipageSrc fetchgit hash…"
# Reset to lib.fakeHash (typed SRI) so the build surfaces the real narHash as
# a "got:" mismatch (works on every bump, not just the first).
perl -0pi -e 's/(aipageSrc = pkgs\.fetchgit \{\n    url = [^\n]+\n    rev = aipageRev;\n    hash = ).*?(;)/${1}pkgs.lib.fakeHash${2}/' nix/packages/aipage.nix
err=$(nix build .#aipage-firefox --no-link 2>&1 || true)
if echo "$err" | grep -q 'got:.*sha256-'; then
  got=$(echo "$err" | grep -oE 'got:.*sha256-[A-Za-z0-9+/=]+' | grep -oE 'sha256-[A-Za-z0-9+/=]+' | head -1)
  echo "  aipageSrc fetchgit hash: $got"
  perl -0pi -e 's/hash = pkgs\.lib\.fakeHash;/hash = "'"$got"'";/' nix/packages/aipage.nix
else
  echo "$err" >&2
  echo "aipage: no aipageSrc fetchgit hash mismatch surfaced (unexpected). Inspect the build log above." >&2
  exit 1
fi

# 4. Refresh the fetchCargoVendor hash the same way (aipageSrc is now correct,
#    so the build proceeds to cargoDeps and surfaces its mismatch).
echo "[aipage] refreshing fetchCargoVendor hash…"
perl -0pi -e 's/(fetchCargoVendor \{\n    src = aipageSrc;\n    hash = ).*?(;)/${1}pkgs.lib.fakeHash${2}/' nix/packages/aipage.nix
err=$(nix build .#aipage-firefox --no-link 2>&1 || true)
if echo "$err" | grep -q 'got:.*sha256-'; then
  got=$(echo "$err" | grep -oE 'got:.*sha256-[A-Za-z0-9+/=]+' | grep -oE 'sha256-[A-Za-z0-9+/=]+' | head -1)
  echo "  fetchCargoVendor hash: $got"
  perl -0pi -e 's/hash = pkgs\.lib\.fakeHash;/hash = "'"$got"'";/' nix/packages/aipage.nix
else
  echo "$err" >&2
  echo "aipage: no fetchCargoVendor hash mismatch surfaced (unexpected). Inspect the build log above." >&2
  exit 1
fi

# 5. Verify: both dists build and the flake evals.
echo "[aipage] building .#aipage-firefox .#aipage-chrome…"
nix build .#aipage-firefox .#aipage-chrome --no-link --print-out-paths
echo "[aipage] nix flake check --no-build…"
nix flake check --no-build

cat <<EOF

Done. aipage pinned at $rev. Review and commit:
  git add nix/packages/aipage.nix nix/packages/aipage-bun.nix flake.lock
  git commit -m "fix: build aipage in-flake (pin $rev)"
EOF