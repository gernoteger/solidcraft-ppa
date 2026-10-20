#!/usr/bin/env bash
# Download the upstream Linux .debs for a release and record their metadata.
#
# Usage: scripts/fetch-upstream.sh [TAG]
#   TAG defaults to the latest GitHub release.
#
# Writes vendor/solidcraft-linux-{x86_64,aarch64}.deb, vendor/SHA256SUMS.txt
# and vendor/metadata.env.
set -euo pipefail

repo=${UPSTREAM_REPO:-tangency-labs/solidcraft}
vendor=${VENDOR_DIR:-vendor}
tag=${1:-}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

mkdir -p "$vendor"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

auth=()
if [[ -n ${GH_TOKEN:-} ]]; then
  auth=(-H "Authorization: Bearer $GH_TOKEN")
fi

if [[ -n $tag ]]; then
  api_url="https://api.github.com/repos/$repo/releases/tags/$tag"
else
  api_url="https://api.github.com/repos/$repo/releases/latest"
fi

curl -fsSL "${auth[@]}" -H 'Accept: application/vnd.github+json' \
  "$api_url" -o "$tmp/release.json" ||
  die "cannot read release information from $api_url"

read -r tag published < <(python3 - "$tmp/release.json" <<'PY'
import json
import sys

release = json.load(open(sys.argv[1]))
print(release["tag_name"], release.get("published_at") or "")
PY
)

python3 - "$tmp/release.json" > "$tmp/assets.txt" <<'PY'
import json
import sys

wanted = {
    "solidcraft-linux-x86_64.deb",
    "solidcraft-linux-aarch64.deb",
    "SHA256SUMS.txt",
}
release = json.load(open(sys.argv[1]))
for asset in release["assets"]:
    if asset["name"] in wanted:
        print(asset["name"], asset["browser_download_url"])
PY

while read -r name url; do
  [[ -n $name ]] || continue
  echo "Downloading $name"
  curl -fL --retry 3 --retry-delay 2 -o "$vendor/$name" "$url"
done < "$tmp/assets.txt"

for name in solidcraft-linux-x86_64.deb solidcraft-linux-aarch64.deb SHA256SUMS.txt; do
  [[ -f "$vendor/$name" ]] || die "$name is missing from release $tag"
done

(
  cd "$vendor"
  grep -E '  solidcraft-linux-(x86_64|aarch64)\.deb$' SHA256SUMS.txt |
    sha256sum -c -
)

x86_version=$(dpkg-deb -f "$vendor/solidcraft-linux-x86_64.deb" Version)
arm_version=$(dpkg-deb -f "$vendor/solidcraft-linux-aarch64.deb" Version)
[[ $x86_version == "$arm_version" ]] ||
  die "version mismatch: x86_64=$x86_version aarch64=$arm_version"

[[ $(dpkg-deb -f "$vendor/solidcraft-linux-x86_64.deb" Package) == solidcraft ]] ||
  die "unexpected package name in x86_64 deb"
[[ $(dpkg-deb -f "$vendor/solidcraft-linux-x86_64.deb" Architecture) == amd64 ]] ||
  die "unexpected architecture in x86_64 deb"
[[ $(dpkg-deb -f "$vendor/solidcraft-linux-aarch64.deb" Architecture) == arm64 ]] ||
  die "unexpected architecture in aarch64 deb"

# 0.17.0-1 becomes 0.17.0-1ppa2, which sorts above upstream's own deb.
deb_version="${x86_version}ppa2"
upstream_version="${x86_version%-*}"
[[ -n $published ]] || published=$(date -u +%Y-%m-%dT%H:%M:%SZ)

cat > "$vendor/metadata.env" <<EOF
UPSTREAM_TAG='$tag'
UPSTREAM_VERSION='$upstream_version'
DEB_VERSION='$deb_version'
UPSTREAM_DATE='$published'
UPSTREAM_URL='https://github.com/$repo/releases/tag/$tag'
EOF

printf 'Upstream %s: %s (%s)\n' "$tag" "$deb_version" "$published"
