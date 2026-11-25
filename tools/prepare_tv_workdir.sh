#!/usr/bin/env bash
# Create an isolated source copy for one TV dependency profile.
set -euo pipefail

if [[ $# -ne 1 || ( "$1" != "tizen" && "$1" != "webos" ) ]]; then
  echo "usage: prepare_tv_workdir.sh <tizen|webos>" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM="$1"
if [[ -n "${ZANZIBARR_TV_WORKDIR:-}" ]]; then
  WORK="$ZANZIBARR_TV_WORKDIR"
else
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/zanzibarr-${PLATFORM}.XXXXXX")"
fi
mkdir -p "$WORK"

rsync -a --delete \
  --exclude=.git \
  --exclude=.dart_tool \
  --exclude=build \
  --exclude=dist \
  --exclude=rust/target \
  --exclude=tizen/lib \
  --exclude=rust_builder/webos/lib \
  --exclude=.DS_Store \
  --exclude=kimi-export-\* \
  "$ROOT/" "$WORK/"

if command -v dart >/dev/null 2>&1; then
  DART=dart
elif [[ -n "${FLUTTER_TIZEN_HOME:-}" && -x "$FLUTTER_TIZEN_HOME/bin/cache/dart-sdk/bin/dart" ]]; then
  DART="$FLUTTER_TIZEN_HOME/bin/cache/dart-sdk/bin/dart"
elif [[ -n "${FLUTTER_WEBOS_HOME:-}" && -x "$FLUTTER_WEBOS_HOME/bin/cache/dart-sdk/bin/dart" ]]; then
  DART="$FLUTTER_WEBOS_HOME/bin/cache/dart-sdk/bin/dart"
else
  echo "error: dart executable not found" >&2
  exit 1
fi
"$DART" "$ROOT/tools/configure_tv_pubspec.dart" "$WORK" "$PLATFORM"
printf '%s\n' "$WORK"
