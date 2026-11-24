#!/usr/bin/env bash
# Builds ChiakiKit.xcframework (chiaki-ng core + deps) for iOS device and simulator.
#
#   scripts/build-chiaki.sh            # Release
#   CONFIG=Debug scripts/build-chiaki.sh
#   SLICES=ios scripts/build-chiaki.sh  # device only (release CI); no simulator support
#
# Output: Frameworks/ChiakiKit.xcframework
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-Release}"
MIN_IOS="${MIN_IOS:-17.0}"
SLICES="${SLICES:-ios sim}"
BUILD="$ROOT/build/chiakikit"
OUT="$ROOT/Frameworks/ChiakiKit.xcframework"

build_slice() {
	local name="$1" sysroot="$2"
	local dir="$BUILD/$name"
	cmake -S "$ROOT/ChiakiKit" -B "$dir" -G Ninja \
		-DCMAKE_SYSTEM_NAME=iOS \
		-DCMAKE_OSX_SYSROOT="$sysroot" \
		-DCMAKE_OSX_ARCHITECTURES=arm64 \
		-DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_IOS" \
		-DCMAKE_BUILD_TYPE="$CONFIG" \
		-DCMAKE_POLICY_VERSION_MINIMUM=3.5 >/dev/null
	cmake --build "$dir"
	# Merge every static lib into one archive
	local libs
	libs=$(find "$dir" -name '*.a' ! -name 'libChiakiKit.a')
	libtool -static -no_warning_for_no_symbols -o "$dir/libChiakiKit.a" $libs
}

XCF_ARGS=()
for slice in $SLICES; do
	case "$slice" in
	ios) build_slice ios iphoneos ;;
	sim) build_slice sim iphonesimulator ;;
	*) echo "Unknown slice '$slice' (expected ios and/or sim)" >&2; exit 1 ;;
	esac
done

# Public headers: only the bridge. chiaki's own headers stay private.
HDR="$BUILD/headers"
rm -rf "$HDR"
mkdir -p "$HDR"
cp "$ROOT/ChiakiKit/include/ck_bridge.h" "$HDR/"
cat > "$HDR/module.modulemap" <<'EOF'
module ChiakiKit {
    header "ck_bridge.h"
    export *
}
EOF

for slice in $SLICES; do
	XCF_ARGS+=(-library "$BUILD/$slice/libChiakiKit.a" -headers "$HDR")
done

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
xcodebuild -create-xcframework "${XCF_ARGS[@]}" -output "$OUT" >/dev/null

echo "Built $OUT ($SLICES)"

# Sanity check: report undefined chiaki/ck symbols that nothing in the archive defines
CHECK_LIB="$BUILD/${SLICES%% *}/libChiakiKit.a"
UNDEF=$(nm -u "$CHECK_LIB" 2>/dev/null | grep -E '^_(chiaki|ck_|holepunch)' | sort -u || true)
DEF=$(nm -gU "$CHECK_LIB" 2>/dev/null | awk '{print $3}' | sort -u)
MISSING=$(comm -23 <(echo "$UNDEF") <(echo "$DEF") | grep -v '^$' || true)
if [ -n "$MISSING" ]; then
	echo "WARNING: unresolved chiaki symbols:" >&2
	echo "$MISSING" >&2
	exit 1
fi
