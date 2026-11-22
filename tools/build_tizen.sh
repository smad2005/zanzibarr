#!/usr/bin/env bash
# Build Zanzibarr for Samsung Tizen TV (armel / softfp).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API="${1:-6.0}"
if [[ "$API" != "6.0" && "$API" != "10.0" ]]; then
  echo "usage: build_tizen.sh [6.0|10.0]" >&2
  exit 2
fi
if [[ -n "${FLUTTER_TIZEN_HOME:-}" ]]; then
  export PATH="$FLUTTER_TIZEN_HOME/bin:$PATH"
fi
command -v flutter-tizen >/dev/null || {
  echo "error: flutter-tizen is not in PATH (set FLUTTER_TIZEN_HOME)." >&2
  exit 1
}
: "${TIZEN_SDK:?Set TIZEN_SDK to the installed Tizen SDK root}"

if [[ "$API" == "6.0" ]]; then
  GCC_VERSION="${TIZEN_GCC_VERSION:-9.2}"
  DEFAULT_SYSROOT="$TIZEN_SDK/platforms/tizen-6.0/iot-headed/rootstraps/iot-headed-6.0-device.core"
else
  GCC_VERSION="${TIZEN_GCC_VERSION:-14.2}"
  DEFAULT_SYSROOT="$TIZEN_SDK/platforms/tizen-10.0/tizen/rootstraps/tizen-10.0-device.core"
fi
TOOLCHAIN="${TIZEN_TOOLCHAIN:-$TIZEN_SDK/tools/arm-linux-gnueabi-gcc-$GCC_VERSION}"
SYSROOT="${TIZEN_SYSROOT:-$DEFAULT_SYSROOT}"
TRIPLE=arm-linux-gnueabi
for tool in gcc g++ ar; do
  test -x "$TOOLCHAIN/bin/$TRIPLE-$tool" || {
    echo "error: missing Tizen toolchain binary: $TOOLCHAIN/bin/$TRIPLE-$tool" >&2
    exit 1
  }
done
test -d "$SYSROOT" || {
  echo "error: Tizen sysroot not found: $SYSROOT (override with TIZEN_SYSROOT)." >&2
  exit 1
}

WORK="$($ROOT/tools/prepare_tv_workdir.sh tizen | tail -1)"
cleanup() {
  status=$?
  if [[ $status -eq 0 && "${ZANZIBARR_TV_KEEP_WORKDIR:-0}" != "1" ]]; then
    rm -rf "$WORK"
  else
    echo "Tizen workdir: $WORK"
  fi
  exit $status
}
trap cleanup EXIT

RUST_TARGET=armv7-unknown-linux-gnueabi
rustup target add "$RUST_TARGET"
TUNE="-march=armv7-a -mtune=cortex-a8 -mthumb -mfpu=vfpv3-d16 -mfloat-abi=softfp"
export CC_armv7_unknown_linux_gnueabi="$TOOLCHAIN/bin/$TRIPLE-gcc"
export CXX_armv7_unknown_linux_gnueabi="$TOOLCHAIN/bin/$TRIPLE-g++"
export AR_armv7_unknown_linux_gnueabi="$TOOLCHAIN/bin/$TRIPLE-ar"
export CFLAGS_armv7_unknown_linux_gnueabi="$TUNE --sysroot=$SYSROOT"
export CXXFLAGS_armv7_unknown_linux_gnueabi="$TUNE --sysroot=$SYSROOT"
export TARGET_CC="$CC_armv7_unknown_linux_gnueabi"
export TARGET_AR="$AR_armv7_unknown_linux_gnueabi"
export TARGET_CFLAGS="$CFLAGS_armv7_unknown_linux_gnueabi"
export CARGO_TARGET_ARMV7_UNKNOWN_LINUX_GNUEABI_LINKER="$TOOLCHAIN/bin/$TRIPLE-g++"
LIBSTDCXX_A="$("$CXX_armv7_unknown_linux_gnueabi" $TUNE -print-file-name=libstdc++.a)"
if [[ "$LIBSTDCXX_A" == "libstdc++.a" || ! -f "$LIBSTDCXX_A" ]]; then
  echo "error: the Tizen toolchain does not provide libstdc++.a" >&2
  exit 1
fi
STDCXX_DIR="$WORK/.tizen-static-stdcxx"
mkdir -p "$STDCXX_DIR"
cp "$LIBSTDCXX_A" "$STDCXX_DIR/libstdc++.a"
# rustc emits its native -lstdc++ records before user link arguments. Put an
# archive-only directory first so every record resolves statically regardless
# of argument order; -static-libstdc++ alone is insufficient with rustc's
# -nodefaultlibs link.
export CARGO_TARGET_ARMV7_UNKNOWN_LINUX_GNUEABI_RUSTFLAGS="\
-L native=$STDCXX_DIR \
-C link-arg=--sysroot=$SYSROOT \
-C link-arg=-march=armv7-a \
-C link-arg=-mtune=cortex-a8 \
-C link-arg=-mthumb \
-C link-arg=-mfpu=vfpv3-d16 \
-C link-arg=-mfloat-abi=softfp \
-C link-arg=-Wl,-soname,librust_lib_zanzibarr.so"

cargo build \
  --manifest-path "$WORK/rust/Cargo.toml" \
  --target "$RUST_TARGET" \
  --release --lib --locked

ENGINE="$WORK/rust/target/$RUST_TARGET/release/librust_lib_zanzibarr.so"
test -f "$ENGINE"
mkdir -p "$WORK/tizen/lib"
cp "$ENGINE" "$WORK/tizen/lib/"
if [[ "$API" == "10.0" ]]; then
  cp "$WORK/tizen/tizen-manifest-10.0.xml" "$WORK/tizen/tizen-manifest.xml"
fi

cd "$WORK"
flutter-tizen build tpk \
  --release \
  --target lib/tv_main.dart \
  --target-arch arm \
  --device-profile tv \
  --dart-define=ZANZIBARR_TV_OS=tizen

TPK="$(find "$WORK/build/tizen/tpk" -name '*.tpk' -print -quit)"
test -n "$TPK" && test -f "$TPK"
mkdir -p "$ROOT/dist/tizen"
cp "$TPK" "$ROOT/dist/tizen/zanzibarr-tizen-$API-arm.tpk"
echo "Built: $ROOT/dist/tizen/zanzibarr-tizen-$API-arm.tpk"
