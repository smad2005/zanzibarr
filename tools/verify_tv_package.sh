#!/usr/bin/env bash
# Verify the native engine inside a Tizen TPK or webOS IPK.
set -euo pipefail

if [[ $# -ne 2 || ( "$1" != "tizen" && "$1" != "webos" ) ]]; then
  echo "usage: verify_tv_package.sh <tizen|webos> <package>" >&2
  exit 2
fi
KIND="$1"
PKG="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
test -f "$PKG"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ "$KIND" == "tizen" ]]; then
  ENTRY="$(unzip -Z1 "$PKG" | awk '/librust_lib_zanzibarr.so/{print; exit}')"
  test -n "$ENTRY" || {
    echo "error: Rust engine is missing from $PKG" >&2
    exit 1
  }
  CPP_ENTRY="$(unzip -Z1 "$PKG" | awk '/libstdc\+\+.so.6/{print; exit}')"
  test -n "$CPP_ENTRY" || {
    echo "error: the bundled libstdc++.so.6 runtime is missing from $PKG" >&2
    exit 1
  }
  unzip -p "$PKG" "$ENTRY" > "$TMP/engine.so"
else
  ar t "$PKG"
  (
    cd "$TMP"
    ar x "$PKG"
    tar -tzf data.tar.gz | grep 'librust_lib_zanzibarr.so' >/dev/null
    tar -tzf data.tar.gz | grep 'libstdc++.so.6' >/dev/null
    tar -xOf data.tar.gz --wildcards '*/librust_lib_zanzibarr.so' > engine.so
  )
fi

file "$TMP/engine.so"
readelf -h "$TMP/engine.so" | grep -q 'ARM'
readelf -d "$TMP/engine.so" | grep -q 'SONAME.*librust_lib_zanzibarr.so'
readelf -d "$TMP/engine.so" | grep -E 'RPATH|RUNPATH' | grep -F '$ORIGIN/lib' >/dev/null
if readelf -A "$TMP/engine.so" | grep -qi 'Tag_ABI_VFP_args: VFP registers'; then
  echo "error: hard-float ABI detected; Tizen/webOS require softfp" >&2
  exit 1
fi

echo "Native TV engine verified in $PKG"
