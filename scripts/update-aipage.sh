#!/usr/bin/env bash
# Rebuild AIPage (codeberg.org/dasmatus/aipage) from source and refresh the
# deterministic dist tarballs that nix/home/{brave,librewolf}.nix pull in via
# builtins.fetchTarball (an eval-time FOD — see those files for why a flake
# input can't reach the gitignored sibling dist-* dirs).
#
# Run this whenever you want the browsers to pick up a new aipage build, then
# paste the printed sha256 into nix/home/{brave,librewolf}.nix and
# `sudo nixos-rebuild switch --flake .#tokyonight`.
#
# NB: the tarballs are content-addressed by their narHash, so rebuilding
# aipage changes the hash and Brave's --load-extension path — which means
# Brave sees a *new* unpacked extension (path-derived id, no `key` in the
# MV2 manifest) and loses any in-extension settings (API keys). LibreWolf is
# unaffected (stable gecko id). Add a `key` to aipage's Chrome manifest to
# give Brave a stable id if that becomes annoying.
set -euo pipefail

AIPAGE=${AIPAGE:-$HOME/Dokumente/codeberg/personal/aipage}
TARDIR=${TARDIR:-$HOME/.local/share/aipage}

cd "$AIPAGE"
echo "[aipage] building chrome + firefox from source (nix run .#build)…"
nix run .#build -- chrome
nix run .#build -- firefox

mkdir -p "$TARDIR"
for t in chrome firefox; do
  tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
    -cf "$TARDIR/dist-$t.tar" -C "dist-$t" .
  # builtins.fetchTarball prints the real narHash as a hash-mismatch error
  # when fed lib.fakeSha256; grab the "got:" sha256 from it.
  h=$(
    nix eval --impure --expr \
      "let pkgs=import <nixpkgs>{}; in builtins.fetchTarball { url=\"file://$TARDIR/dist-$t.tar\"; sha256=pkgs.lib.fakeSha256; }" \
      2>&1 | grep -oE 'got: +sha256:[a-z0-9]+' | grep -oE '[a-z0-9]{52}'
  )
  printf '  dist-%s.tar  sha256 = "%s";\n' "$t" "$h"
done

cat <<EOF

Now update the sha256 in:
  nix/home/librewolf.nix   (aipageFirefox, dist-firefox.tar)
  nix/home/brave.nix       (aipageChrome,  dist-chrome.tar)
and:
  sudo nixos-rebuild switch --flake .#tokyonight
EOF