#!/usr/bin/env bash
# Write the GitHub Pages site that hands out the LiveISO from GHCR.
#
#   REPO=dasmatus/dots PAGES_URL=https://dasmatus.github.io/dots \
#     [PROXY_URL=https://…] pages-site.sh <out-dir>
#
# The site is regenerated from GHCR on every deploy, never accumulated: for
# each channel it reads the manifest of ghcr.io/<repo>/images:<channel>-x86_64
# (the artifact .github/workflows/iso.yml pushes) and writes, under
# updates/<channel>/x86_64/,
#   SHA256SUMS    the layer of that name, verbatim;
#   blobs.txt     `<digest>\t<file>` per layer, which get-iso.sh reads;
#   release.json  the manifest's annotations plus the ISO's name, size and
#                 digest.
# A channel GHCR does not have yet is skipped, not an error.
#
# That is the path the LosOS Desktop proxy answers at
# /updates/<channel>/<arch>/<file>. Pages runs no code, so the ISO itself is
# not here: 404.html sends a request for it on to PROXY_URL (a deployment of
# that proxy with GHCR_REPOSITORY=<repo>) when one is set, and get-iso.sh
# fetches it from GHCR directly when not.
set -euo pipefail

out=${1:?usage: pages-site.sh <out-dir>}
: "${REPO:?REPO=owner/name is required}"
: "${PAGES_URL:?PAGES_URL is required}"
proxy=${PROXY_URL:-}
proxy=${proxy%/}
pages=${PAGES_URL%/}
channels=${CHANNELS:-main stable}
arch=x86_64
repository="ghcr.io/${REPO,,}/images"
here=$(dirname "$(realpath "$0")")

rm -rf "$out"
mkdir -p "$out"
touch "$out/.nojekyll"

# The published copy points at this site rather than the default.
sed "s|^pages=\${DOTS_PAGES_URL:-[^}]*}|pages=\${DOTS_PAGES_URL:-$pages}|" \
  "$here/get-iso.sh" > "$out/get-iso.sh"
grep -q "DOTS_PAGES_URL:-$pages}" "$out/get-iso.sh"

rows=""
for channel in $channels; do
  ref="$repository:$channel-$arch"
  dir="$out/updates/$channel/$arch"
  if ! manifest=$(oras manifest fetch "$ref" 2>/dev/null); then
    echo "pages-site: $ref not published yet, skipping"
    continue
  fi
  mkdir -p "$dir"
  jq -r '.layers[] | "\(.digest)\t\(.annotations["org.opencontainers.image.title"] // "")"' \
    <<< "$manifest" > "$dir/blobs.txt"
  if ! grep -q $'\t.*\\.iso$' "$dir/blobs.txt"; then
    echo "pages-site: $ref has no ISO layer, skipping"
    rm -rf "$dir"
    continue
  fi
  sums=$(awk -F '\t' '$2 == "SHA256SUMS" { print $1 }' "$dir/blobs.txt")
  [ -n "$sums" ] || { echo "pages-site: $ref has no SHA256SUMS layer" >&2; exit 1; }
  oras blob fetch --output "$dir/SHA256SUMS" "$repository@$sums"
  jq --arg ref "$ref" '
    (.layers[] | select(.annotations["org.opencontainers.image.title"] | test("\\.iso$"))) as $iso
    | (.annotations // {}) + {
        reference: $ref,
        iso: $iso.annotations["org.opencontainers.image.title"],
        size: $iso.size,
        digest: $iso.digest
      }' <<< "$manifest" > "$dir/release.json"
  iso=$(jq -r .iso "$dir/release.json")
  size=$(jq -r .size "$dir/release.json")
  version=$(jq -r '.["org.opencontainers.image.version"] // "?"' "$dir/release.json")
  revision=$(jq -r '.["org.opencontainers.image.revision"] // ""' "$dir/release.json")
  sha=$(awk -v f="$iso" '$2 == f { print $1 }' "$dir/SHA256SUMS")
  human=$(awk -v b="$size" 'BEGIN { printf "%.2f GiB", b / 1073741824 }')
  if [ -n "$proxy" ]; then
    link="<a href=\"$proxy/updates/$channel/$arch/$iso\">$iso</a>"
  else
    link="<code>$iso</code>"
  fi
  rows+="<tr><td><b>$channel</b></td><td>$link<br><small>$human · $version"
  [ -n "$revision" ] && rows+=" · <a href=\"https://github.com/$REPO/commit/$revision\">${revision:0:7}</a>"
  rows+="</small></td><td><code class=\"sum\">$sha</code></td>"
  rows+="<td><a href=\"updates/$channel/$arch/SHA256SUMS\">SHA256SUMS</a></td></tr>"$'\n'
done
[ -n "$rows" ] || rows='<tr><td colspan="4">Nothing published yet: the first <code>iso</code> run on main fills this in.</td></tr>'

style='
:root { --bg:#1a1b26; --fg:#c0caf5; --dim:#787c99; --accent:#7aa2f7; --panel:#24283b; color-scheme: dark; }
@media (prefers-color-scheme: light) {
  :root { --bg:#e1e2e7; --fg:#3760bf; --dim:#6172b0; --accent:#2e7de9; --panel:#d0d5e3; color-scheme: light; }
}
* { box-sizing: border-box; }
body { margin: 0; padding: 2rem 16px; background: var(--bg); color: var(--fg);
  font: 16px/1.5 system-ui, sans-serif; }
main { max-width: 56rem; margin: 0 auto; }
a { color: var(--accent); }
h1 { margin-top: 0; }
pre, code { font-family: ui-monospace, monospace; font-size: .9em; }
pre { background: var(--panel); padding: .75rem 1rem; border-radius: 6px; overflow-x: auto; }
table { width: 100%; border-collapse: collapse; display: block; overflow-x: auto; }
td { padding: .5rem; border-top: 1px solid var(--panel); vertical-align: top; }
small, .dim { color: var(--dim); }
.sum { word-break: break-all; font-size: .75em; }
'

cat > "$out/index.html" <<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>tokyonight-dots ISO</title>
<style>$style</style>
</head>
<body>
<main>
<h1>tokyonight-dots LiveISO</h1>
<p>The full installer image, with the prebuilt system closure embedded for an
offline install. CI builds it on every push to <code>main</code> (channel
<b>main</b>) and every <code>v*</code> tag (channel <b>stable</b>) and pushes it
to <a href="https://github.com/$REPO/pkgs/container/${REPO#*/}%2Fimages">GHCR</a>.</p>
<table>
$rows</table>
<h2>Download</h2>
<pre>curl -fsSL $pages/get-iso.sh | sh                  # main
curl -fsSL $pages/get-iso.sh | sh -s -- stable      # newest tag</pre>
<p class="dim">The script fetches the ISO from GHCR and checks it against the
channel's SHA256SUMS. With <a href="https://oras.land">oras</a> instead:</p>
<pre>oras pull $repository:main-$arch</pre>
<p>Write it to a USB stick and boot it; the installer starts on tty1.</p>
<pre>sudo dd if=tokyonight-dots-installer-full-*.iso of=/dev/sdX bs=4M oflag=sync status=progress</pre>
</main>
</body>
</html>
HTML

# Pages answers a path it has no file for with this page. A request for an
# ISO under updates/ goes on to the proxy when there is one; anything else is
# a plain not-found.
cat > "$out/404.html" <<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Not found</title>
<style>$style</style>
<script>
(function () {
  var proxy = "$proxy";
  var m = location.pathname.match(/\/(updates\/[a-z0-9][a-z0-9.-]{0,31}\/$arch\/[A-Za-z0-9._+-]+\.iso)$/);
  if (proxy && m) location.replace(proxy + "/" + m[1]);
})();
</script>
</head>
<body>
<main>
<h1>Not here</h1>
<p>Pages carries the checksums and the download script, not the ISO itself.
See <a href="$pages/">the download page</a>.</p>
</main>
</body>
</html>
HTML

find "$out" -type f | sort
