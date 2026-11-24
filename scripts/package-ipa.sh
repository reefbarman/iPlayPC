#!/usr/bin/env bash
# Builds an unsigned build/iPlayPC.ipa for sideloading. SideStore, AltStore and
# Sideloadly re-sign it with the installer's own Apple ID.
#
#   scripts/package-ipa.sh
#   VERSION=0.2.0 BUILD_NUMBER=7 scripts/package-ipa.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-0.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
BUNDLE_ID="${BUNDLE_ID:-io.github.reefbarman.iplaypc}"
# Settings › About › Source code links here (AGPL-3.0)
if [ "$VERSION" = 0.0.0 ]; then SOURCE_REF="${SOURCE_REF:-main}"; else SOURCE_REF="${SOURCE_REF:-v$VERSION}"; fi
DERIVED="$ROOT/build/DerivedData-ipa"
STAGE="$ROOT/build/ipa"
OUT="$ROOT/build/iPlayPC.ipa"

[ -d Frameworks/IHSKit.xcframework ] || SLICES=ios scripts/build-ihskit.sh
xcodegen generate

xcodebuild -project iPlayPC.xcodeproj -scheme iPlayPC -configuration Release \
	-destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" \
	CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="" \
	IPLAYPC_BUNDLE_ID="$BUNDLE_ID" IPLAYPC_SOURCE_REF="$SOURCE_REF" MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
	build

rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE/Payload"
cp -R "$DERIVED/Build/Products/Release-iphoneos/iPlayPC.app" "$STAGE/Payload/"
(cd "$STAGE" && zip -qry "$OUT" Payload)
echo "Built $OUT"
