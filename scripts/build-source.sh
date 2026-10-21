#!/usr/bin/env bash
# Build a signed Debian source package for one Ubuntu series from the vendored
# upstream debs.
#
# Usage: scripts/build-source.sh SERIES [DATE] [GPG_KEY_ID]
#   SERIES     Ubuntu series the .changes file targets, e.g. noble or resolute
#   DATE       RFC 3339 timestamp used for the changelog (default: now)
#   GPG_KEY_ID signing key; without it the package is left unsigned
#
# Requires vendor/metadata.env from scripts/fetch-upstream.sh.
set -euo pipefail

series=${1:?usage: build-source.sh SERIES [DATE] [GPG_KEY_ID]}
date=${2:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
key=${3:-}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ -f vendor/metadata.env ]] ||
  die "vendor/metadata.env is missing; run scripts/fetch-upstream.sh first"
# shellcheck source=/dev/null
. vendor/metadata.env

for field in UPSTREAM_VERSION DEB_VERSION UPSTREAM_DATE UPSTREAM_TAG UPSTREAM_URL; do
  [[ -n ${!field:-} ]] || die "$field is empty in vendor/metadata.env"
done
[[ -f debian/control ]] || die "run this from the packaging repository root"

release_epoch=$(date -u -d "$UPSTREAM_DATE" +%s) ||
  die "invalid UPSTREAM_DATE: $UPSTREAM_DATE"
release_date=$(date -u -R -d "@$release_epoch")
maintainer=$(sed -n 's/^Maintainer: *//p' debian/control | head -n1)

# The changelog distribution is deliberately constant: Launchpad keys the
# files listed in the .dsc by version, so every series must upload a
# byte-identical .orig.tar.gz and .debian.tar.xz. The target series goes into
# the .changes file below, which is what Launchpad uses to route the upload.
cat > debian/changelog <<EOF
solidcraft ($DEB_VERSION) unstable; urgency=medium

  * Repackage upstream $UPSTREAM_TAG Linux binaries.
    See $UPSTREAM_URL.

 -- $maintainer  $release_date
EOF

# Normalise file timestamps: dpkg-source copies the mtimes of debian/ into
# the .debian.tar.xz, so two checkouts (one per series, or one per run) would
# otherwise produce different files and Launchpad would reject the second
# series for a version it already has.
find . -path ./.git -prune -o -exec touch -h -d "@$release_epoch" {} +

# The orig tarball is immutable for a given upstream version: Launchpad
# rejects a later packaging revision whose orig differs, so reuse the copy the
# PPA already publishes and overlay the current debian/ on it. Otherwise
# create it from this tree, which then doubles as the build tree.
orig="../solidcraft_${UPSTREAM_VERSION}.orig.tar.gz"
source_name=$(sed -n 's/^Source: *//p' debian/control | head -n1)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

reuse_orig=
if [[ -n $source_name && -n ${LP_OWNER:-} && -n ${LP_ARCHIVE:-} ]]; then
  orig_url="https://ppa.launchpadcontent.net/${LP_OWNER}/${LP_ARCHIVE}/ubuntu"
  orig_url="$orig_url/pool/main/${source_name:0:1}/${source_name}/$(basename "$orig")"
  if curl -fsS --retry 3 -o "$orig" "$orig_url"; then
    reuse_orig=1
    printf 'reusing published %s\n' "$(basename "$orig")" >&2
  else
    rm -f "$orig"
  fi
fi

if [[ -n $reuse_orig ]]; then
  tar -xzf "$orig" -C "$tmp"
  build_tree="$tmp/solidcraft-$UPSTREAM_VERSION"
  rm -rf "$build_tree/debian"
  cp -a debian "$build_tree/debian"
  cp "$orig" "$tmp/"
else
  # The orig tarball holds everything except debian/ (and the VCS directory),
  # so the binaries stay byte-identical and dpkg-source has nothing to patch.
  build_tree="$tmp/solidcraft-$UPSTREAM_VERSION"
  mkdir -p "$build_tree"
  tar -cf - --exclude=./debian --exclude=./.git . | tar -xf - -C "$build_tree"

  tar --sort=name \
    --mtime="@$release_epoch" \
    --owner=0 --group=0 --numeric-owner \
    -czf "$orig" \
    -C "$tmp" "solidcraft-$UPSTREAM_VERSION"
  cp -a debian "$build_tree/debian"
  cp "$orig" "$tmp/" 2>/dev/null || true
fi

export SOURCE_DATE_EPOCH=$release_epoch

if [[ -n $key ]]; then
  ( cd "$build_tree" && dpkg-buildpackage -S -sa -k"$key" ) || die "dpkg-buildpackage failed"
else
  ( cd "$build_tree" && dpkg-buildpackage -S -sa -us -uc ) || die "dpkg-buildpackage failed"
fi

# dpkg-buildpackage wrote the source package next to the build tree.
mv "$tmp"/solidcraft_* ..

changes="../solidcraft_${DEB_VERSION}_source.changes"
[[ -f $changes ]] || die "expected $changes"

# Route the upload to this series and re-sign, since editing a signed
# .changes file invalidates the signature.
sed -i "s/^Distribution: .*/Distribution: $series/" "$changes"
if [[ -n $key ]]; then
  command -v debsign >/dev/null ||
    die "debsign (devscripts) is required to re-sign $changes"
  debsign --re-sign -k"$key" "$changes" >/dev/null
fi

printf '%s\n' "$changes"
