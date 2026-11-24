#!/usr/bin/env bash
# Copies the licence texts of iPlayPC and everything bundled into it to
# App/Resources/Licenses, where Settings › About › Licences shows them.
# The output is committed so builds don't need the submodules checked out.
# Run it again after bumping a submodule or ihslib and commit any changes.
#
#   scripts/update-licenses.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUT=App/Resources/Licenses

copy() { # source, destination name
	if [ ! -f "$1" ]; then
		echo "Missing $1. Run: git submodule update --init" >&2
		exit 1
	fi
	cp "$1" "$OUT/$2"
}

rm -rf "$OUT"
mkdir -p "$OUT"

copy LICENSE iPlayPC.txt
copy vendor/ihslib/LICENSE ihslib.txt
copy Licenses/Steam-Link-PS5-GPL-3.0.txt Steam-Link-PS5.txt
copy vendor/mbedtls/LICENSE MbedTLS.txt
copy vendor/opus/COPYING Opus.txt
copy vendor/protobuf-c/LICENSE protobuf-c.txt

echo "Updated $OUT"
