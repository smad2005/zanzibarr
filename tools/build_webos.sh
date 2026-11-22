#!/usr/bin/env bash
# Build Zanzibarr for LG webOS 26 Re:New+ (ca9v1 ARM / softfp).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "error: flutter-webOS builds require Ubuntu Linux (use CI or the official Dev Container)." >&2
  exit 1
fi
if [[ -n "${FLUTTER_WEBOS_HOME:-}" ]]; then
  export PATH="$FLUTTER_WEBOS_HOME/bin:$PATH"
fi
command -v flutter-webos >/dev/null || {
  echo "error: flutter-webos is not in PATH (set FLUTTER_WEBOS_HOME)." >&2
  exit 1
}
: "${WEBOS_FLUTTER_NDK_ENV:?Set WEBOS_FLUTTER_NDK_ENV to the LG environment-setup script}"
# shellcheck source=/dev/null
source "$WEBOS_FLUTTER_NDK_ENV"
: "${CROSS_COMPILE:?LG NDK did not set CROSS_COMPILE}"
: "${SDKTARGETSYSROOT:?LG NDK did not set SDKTARGETSYSROOT}"

GCC_BIN="$(command -v "${CROSS_COMPILE}gcc")"
GXX_BIN="$(command -v "${CROSS_COMPILE}g++")"
AR_BIN="$(command -v "${CROSS_COMPILE}gcc-ar" || command -v "${CROSS_COMPILE}ar")"
for tool in "$GCC_BIN" "$GXX_BIN" "$AR_BIN"; do
  test -x "$tool" || {
    echo "error: missing webOS NDK compiler: $tool" >&2
    exit 1
  }
done

WORK="$($ROOT/tools/prepare_tv_workdir.sh webos | tail -1)"
cleanup() {
  status=$?
  if [[ $status -eq 0 && "${ZANZIBARR_TV_KEEP_WORKDIR:-0}" != "1" ]]; then
    rm -rf "$WORK"
  else
    echo "webOS workdir: $WORK"
  fi
  exit $status
}
trap cleanup EXIT

RUST_TARGET=armv7-unknown-linux-gnueabi
rustup target add "$RUST_TARGET"
TUNE="-march=armv7-a -mthumb -mfpu=neon -mfloat-abi=softfp --sysroot=$SDKTARGETSYSROOT"
export CC_armv7_unknown_linux_gnueabi="$GCC_BIN"
export CXX_armv7_unknown_linux_gnueabi="$GXX_BIN"
export AR_armv7_unknown_linux_gnueabi="$AR_BIN"
export CFLAGS_armv7_unknown_linux_gnueabi="${CFLAGS:-} $TUNE"
export CXXFLAGS_armv7_unknown_linux_gnueabi="${CXXFLAGS:-} $TUNE"
export TARGET_CC="$GCC_BIN"
export TARGET_AR="$AR_BIN"
export TARGET_CFLAGS="$CFLAGS_armv7_unknown_linux_gnueabi"
export CARGO_TARGET_ARMV7_UNKNOWN_LINUX_GNUEABI_LINKER="$GXX_BIN"
export CARGO_TARGET_ARMV7_UNKNOWN_LINUX_GNUEABI_RUSTFLAGS="\
-C link-arg=--sysroot=$SDKTARGETSYSROOT \
-C link-arg=-march=armv7-a \
-C link-arg=-mthumb \
-C link-arg=-mfpu=neon \
-C link-arg=-mfloat-abi=softfp \
-C link-arg=-Wl,-rpath,\$ORIGIN \
-C link-arg=-Wl,-soname,librust_lib_zanzibarr.so"

cargo build \
  --manifest-path "$WORK/rust/Cargo.toml" \
  --target "$RUST_TARGET" \
  --release --lib --locked

ENGINE="$WORK/rust/target/$RUST_TARGET/release/librust_lib_zanzibarr.so"
test -f "$ENGINE"
LIBSTDCXX="$("$GXX_BIN" $TUNE -print-file-name=libstdc++.so.6)"
if [[ "$LIBSTDCXX" == "libstdc++.so.6" || ! -f "$LIBSTDCXX" ]]; then
  echo "error: the webOS NDK does not provide libstdc++.so.6" >&2
  exit 1
fi
mkdir -p "$WORK/rust_builder/webos/lib"
cp "$ENGINE" "$WORK/rust_builder/webos/lib/"
cp "$LIBSTDCXX" "$WORK/rust_builder/webos/lib/"

cd "$WORK"
flutter-webos precache
flutter-webos build webos \
  --release \
  --target lib/tv_main.dart \
  --target-arch arm \
  --dart-define=ZANZIBARR_TV_OS=webos \
  -j"$(getconf _NPROCESSORS_ONLN)"

IPK="$(find "$WORK/build/webos/arm/release/ipk" -name '*.ipk' -print -quit)"
test -n "$IPK" && test -f "$IPK"
mkdir -p "$ROOT/dist/webos"
cp "$IPK" "$ROOT/dist/webos/zanzibarr-webos26-arm.ipk"
echo "Built: $ROOT/dist/webos/zanzibarr-webos26-arm.ipk"
