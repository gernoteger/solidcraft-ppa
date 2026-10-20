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

# The orig tarball holds everything except debian/ (and the VCS directory), so
# the binaries stay byte-identical and dpkg-source has nothing to patch.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
stage="$tmp/solidcraft-$UPSTREAM_VERSION"
mkdir -p "$stage"
tar -cf - --exclude=./debian --exclude=./.git . | tar -xf - -C "$stage"

tar --sort=name \
  --mtime="@$release_epoch" \
  --owner=0 --group=0 --numeric-owner \
  -czf "../solidcraft_${UPSTREAM_VERSION}.orig.tar.gz" \
  -C "$tmp" "solidcraft-$UPSTREAM_VERSION"

export SOURCE_DATE_EPOCH=$release_epoch

if [[ -n $key ]]; then
  dpkg-buildpackage -S -sa -k"$key"
else
  dpkg-buildpackage -S -sa -us -uc
fi

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
