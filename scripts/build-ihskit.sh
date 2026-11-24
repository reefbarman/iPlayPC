#!/usr/bin/env bash
# Builds IHSKit.xcframework (patched ihslib + mbedTLS + Opus + protobuf-c + our
# bridge) for iOS device and simulator.
#
#   scripts/build-ihskit.sh             # Release
#   CONFIG=Debug scripts/build-ihskit.sh
#   SLICES=ios scripts/build-ihskit.sh  # device only (release CI); no simulator support
#
# Output: Frameworks/IHSKit.xcframework
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-Release}"
MIN_IOS="${MIN_IOS:-17.0}"
SLICES="${SLICES:-ios sim}"
BUILD="$ROOT/build/ihskit"
OUT="$ROOT/Frameworks/IHSKit.xcframework"

for sub in mbedtls opus protobuf-c; do
	if [ ! -e "$ROOT/vendor/$sub/CMakeLists.txt" ] && [ ! -e "$ROOT/vendor/$sub/protobuf-c/protobuf-c.c" ]; then
		echo "vendor/$sub is missing; run: git submodule update --init" >&2
		exit 1
	fi
done

build_slice() {
	local name="$1" sysroot="$2"
	local dir="$BUILD/$name"
	cmake -S "$ROOT/IHSKit" -B "$dir" -G Ninja \
		-DCMAKE_SYSTEM_NAME=iOS \
		-DCMAKE_OSX_SYSROOT="$sysroot" \
		-DCMAKE_OSX_ARCHITECTURES=arm64 \
		-DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_IOS" \
		-DCMAKE_BUILD_TYPE="$CONFIG" \
		-DCMAKE_POLICY_VERSION_MINIMUM=3.5 >/dev/null
	cmake --build "$dir"
	# Merge every static lib into one archive
	local libs
	libs=$(find "$dir" -name '*.a' ! -name 'libIHSKit.a')
	libtool -static -no_warning_for_no_symbols -o "$dir/libIHSKit.a" $libs
}

XCF_ARGS=()
for slice in $SLICES; do
	case "$slice" in
	ios) build_slice ios iphoneos ;;
	sim) build_slice sim iphonesimulator ;;
	*) echo "Unknown slice '$slice' (expected ios and/or sim)" >&2; exit 1 ;;
	esac
done

# Public headers: only the bridge. ihslib's own headers stay private.
HDR="$BUILD/headers"
rm -rf "$HDR"
mkdir -p "$HDR"
cp "$ROOT/IHSKit/include/ihs_bridge.h" "$HDR/"
cat > "$HDR/module.modulemap" <<'EOF'
module IHSKit {
    header "ihs_bridge.h"
    export *
}
EOF

for slice in $SLICES; do
	XCF_ARGS+=(-library "$BUILD/$slice/libIHSKit.a" -headers "$HDR")
done

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
xcodebuild -create-xcframework "${XCF_ARGS[@]}" -output "$OUT" >/dev/null

echo "Built $OUT ($SLICES)"

# Sanity check: undefined IHS/ihk/protobuf-c/mbedtls/opus symbols that nothing in the archive defines
CHECK_LIB="$BUILD/${SLICES%% *}/libIHSKit.a"
UNDEF=$(nm -u "$CHECK_LIB" 2>/dev/null | grep -E '^_(IHS_|ihk_|protobuf_c_|mbedtls_|psa_|opus_)' | sort -u || true)
DEF=$(nm -gU "$CHECK_LIB" 2>/dev/null | awk '{print $3}' | sort -u)
MISSING=$(comm -23 <(echo "$UNDEF") <(echo "$DEF") | grep -v '^$' || true)
if [ -n "$MISSING" ]; then
	echo "ERROR: unresolved symbols in libIHSKit.a:" >&2
	echo "$MISSING" >&2
	exit 1
fi
