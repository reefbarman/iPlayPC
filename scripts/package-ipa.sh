#!/usr/bin/env bash
# Builds an unsigned build/iPlayNow.ipa for sideloading. SideStore, AltStore and
# Sideloadly re-sign it with the installer's own Apple ID.
#
#   scripts/package-ipa.sh
#   VERSION=0.2.0 BUILD_NUMBER=7 scripts/package-ipa.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-0.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
BUNDLE_ID="${BUNDLE_ID:-io.github.reefbarman.iplaynow}"
DERIVED="$ROOT/build/DerivedData-ipa"
STAGE="$ROOT/build/ipa"
OUT="$ROOT/build/iPlayNow.ipa"

[ -d Frameworks/OpenSSL.xcframework ] && [ -d Frameworks/usrsctp.xcframework ] || scripts/prepare-frameworks.sh
xcodegen generate

xcodebuild -project iPlayNow.xcodeproj -scheme iPlayNow -configuration Release \
	-destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" \
	CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="" \
	IPLAYNOW_BUNDLE_ID="$BUNDLE_ID" MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
	build

rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE/Payload"
cp -R "$DERIVED/Build/Products/Release-iphoneos/iPlayNow.app" "$STAGE/Payload/"
(cd "$STAGE" && zip -qry "$OUT" Payload)
echo "Built $OUT"
