#!/usr/bin/env bash
# Print, as a JSON array, the Ubuntu series that do not yet have VERSION
# published in the PPA.
#
# Usage: scripts/missing-series.sh VERSION
#
# VERSION is the base version; the per-series "+SERIES" suffix is appended
# here, because each series holds its own source version.
#
# Environment: LP_OWNER, LP_ARCHIVE, SERIES (space separated).
set -euo pipefail

version=${1:?usage: missing-series.sh VERSION}
owner=${LP_OWNER:-gernoteger}
archive=${LP_ARCHIVE:-solidcraft}
series_list=${SERIES:-noble resolute}
ppa_url="https://api.launchpad.net/1.0/~$owner/+archive/ubuntu/$archive"

missing=()
for series in $series_list; do
  series_version="$version+$series"
  if ! body=$(curl -fsS --get "$ppa_url" \
    --data-urlencode "ws.op=getPublishedSources" \
    --data-urlencode "source_name=solidcraft" \
    --data-urlencode "exact_match=true" \
    --data-urlencode "distro_series=https://api.launchpad.net/1.0/ubuntu/$series" \
    --data-urlencode "ws.size=300"); then
    printf 'error: cannot query %s\n' "$ppa_url" >&2
    printf '       create the PPA and register your signing key first\n' >&2
    exit 1
  fi

  if printf '%s' "$body" | python3 -c '
import json
import sys

version = sys.argv[1]
data = json.load(sys.stdin)
found = any(
    entry.get("source_package_version") == version
    for entry in data.get("entries", [])
)
sys.exit(0 if found else 1)
' "$series_version"; then
    printf '%s already has %s\n' "$series" "$series_version" >&2
  else
    missing+=("$series")
  fi
done

if ((${#missing[@]})); then
  printf '%s\n' "${missing[@]}" |
    python3 -c 'import json, sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))'
else
  echo '[]'
fi
