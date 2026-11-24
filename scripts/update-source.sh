#!/usr/bin/env bash
# Adds a release to altstore-source.json (newest first) so SideStore/AltStore
# users get the update. Run by the release workflow.
#
#   scripts/update-source.sh VERSION path/to/iPlayPC.ipa DOWNLOAD_URL
set -euo pipefail

VERSION="$1"
IPA="$2"
URL="$3"
SRC="$(cd "$(dirname "$0")/.." && pwd)/altstore-source.json"
SIZE=$(stat -f%z "$IPA" 2>/dev/null || stat -c%s "$IPA")
DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

tmp=$(mktemp)
jq --arg v "$VERSION" --arg d "$DATE" --arg u "$URL" --argjson s "$SIZE" '
	.apps[0].versions = (
		[{version: $v, date: $d, downloadURL: $u, size: $s, minOSVersion: "17.0",
		  localizedDescription: "See the release notes on GitHub."}]
		+ [.apps[0].versions[] | select(.version != $v)]
	)' "$SRC" >"$tmp"
mv "$tmp" "$SRC"
echo "Added $VERSION to $SRC"
