#!/usr/bin/env bash
# Compare the systemd this flake's nixpkgs pin ships against upstream
# (github.com/systemd/systemd releases), so a new systemd release, and the
# NEWS that comes with it, is noticed rather than found by accident.
#
# Prints a Markdown report on stdout. Exit status:
#   0  the pin is on upstream's newest stable major
#   10 upstream has a newer stable major than the pin
# Anything else is a failure of the script itself.
#
# Needs nix and git. Used by .github/workflows/systemd-upstream.yml; also
# fine to run by hand from the repo root.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
upstream=https://github.com/systemd/systemd

# The version systemd.package resolves to in the pinned nixpkgs, read through
# the flake's own lock, so it is what `nixos-rebuild` would install.
pinned=$(nix eval --raw --inputs-from "$repo_root" nixpkgs#systemd.version)

# Tags rather than the releases API: no token, no rate limit. Upstream tags a
# major as vNNN, its candidates as vNNN-rcN and point releases as vNNN.M.
tags=$(git ls-remote --tags --refs "$upstream" 'v*' | sed 's|.*refs/tags/||')
latest=$(grep -E '^v[0-9]+$' <<<"$tags" | sort -V | tail -1)
latest_rc=$(grep -E '^v[0-9]+-rc[0-9]+$' <<<"$tags" | sort -V | tail -1 || true)

major() { sed -E 's/^v?([0-9]+).*/\1/' <<<"$1"; }
pinned_major=$(major "$pinned")
latest_major=$(major "$latest")

news() { echo "$upstream/blob/$1/NEWS"; }

echo "| | version |"
echo "|---|---|"
echo "| pinned nixpkgs | \`$pinned\` |"
echo "| upstream stable | [\`$latest\`]($(news "$latest")) |"
if [[ -n $latest_rc ]] && (($(major "$latest_rc") > latest_major)); then
  echo "| upstream release candidate | [\`$latest_rc\`]($(news "$latest_rc")) |"
fi
echo

if ((latest_major > pinned_major)); then
  echo "Upstream systemd $latest_major is out; the pin is still on $pinned_major."
  echo "Read the NEWS sections for every version after $pinned_major before the"
  echo "next lockfile bump picks it up, and check nix/modules/system/systemd.nix"
  echo "for anything a new release makes possible."
  exit 10
fi
echo "The pin is on upstream's newest stable major."
