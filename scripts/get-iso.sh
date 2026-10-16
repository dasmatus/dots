#!/bin/sh
# Download the newest full LiveISO from GHCR and verify it.
#
#   curl -fsSL https://dasmatus.github.io/dots/get-iso.sh | sh
#   curl -fsSL https://dasmatus.github.io/dots/get-iso.sh | sh -s -- stable
#
# The first argument is the channel: `main` (default, every push to main) or
# `stable` (the newest v* tag), or a tag such as `v1.2.0`. The ISO lands in
# the current directory.
#
# .github/workflows/iso.yml pushes each build to
# ghcr.io/dasmatus/dots/images:<channel>-x86_64, one layer per file, which is
# the shape the LosOS Desktop proxy serves at /updates/<channel>/<arch>/<file>.
# GitHub Pages runs no code and GHCR answers a browser with neither CORS nor an
# anonymous blob, so the Pages site cannot redirect to the ISO itself. It
# publishes this script instead, plus a `blobs.txt` (digest and file name per
# layer) and the `SHA256SUMS` of each channel, and the script speaks the
# registry API with curl: an anonymous pull token, then the blob, which GHCR
# redirects to short-lived signed storage. curl drops the Authorization header
# when that redirect leaves ghcr.io, so the token never reaches the storage
# host.
set -eu

channel=${1:-main}
arch=x86_64
pages=${DOTS_PAGES_URL:-https://dasmatus.github.io/dots}
repository=${DOTS_GHCR_REPOSITORY:-dasmatus/dots/images}

case "$channel" in
  [a-z0-9]*) ;;
  *) echo "get-iso: '$channel' is not a channel" >&2; exit 2 ;;
esac

if command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$@"; }
elif command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 "$@"; }
else
  echo "get-iso: neither sha256sum nor shasum is installed" >&2
  exit 1
fi

index=$(mktemp -d)
trap 'rm -rf "$index"' EXIT
base="$pages/updates/$channel/$arch"
curl -fsSL "$base/blobs.txt" -o "$index/blobs.txt" || {
  echo "get-iso: $base/blobs.txt is missing; has CI published the '$channel' channel yet?" >&2
  exit 1
}
curl -fsSL "$base/SHA256SUMS" -o "$index/SHA256SUMS"

iso=$(awk -F '\t' '$2 ~ /\.iso$/ { print $2; exit }' "$index/blobs.txt")
digest=$(awk -F '\t' '$2 ~ /\.iso$/ { print $1; exit }' "$index/blobs.txt")
case "$digest" in
  sha256:*) ;;
  *) echo "get-iso: no ISO layer in the '$channel' channel" >&2; exit 1 ;;
esac

grep "  $iso\$" "$index/SHA256SUMS" > "$index/$iso.sha256"
if [ -f "$iso" ] && sha256 -c "$index/$iso.sha256" >/dev/null 2>&1; then
  cp "$index/$iso.sha256" "$iso.sha256"
  echo "get-iso: $iso is already here and verified"
  exit 0
fi

token=$(curl -fsSL "https://ghcr.io/token?service=ghcr.io&scope=repository:$repository:pull" |
  sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
[ -n "$token" ] || { echo "get-iso: GHCR handed out no pull token" >&2; exit 1; }

echo "get-iso: $iso ($channel) from ghcr.io/$repository"
# -C - resumes a partial download on a re-run: the signed URL differs every
# time, the bytes behind it do not.
curl -fL --retry 5 --retry-delay 5 -C - \
  -H "Authorization: Bearer $token" \
  -o "$iso" "https://ghcr.io/v2/$repository/blobs/$digest"

cp "$index/$iso.sha256" "$iso.sha256"
sha256 -c "$iso.sha256"
echo "get-iso: verified $iso; write it with: sudo dd if=$iso of=/dev/sdX bs=4M oflag=sync status=progress"
