#!/bin/bash
# Debug-only UI previews: temporary rules and fake ssh; never load the user's data.
set -euo pipefail
cd "$(dirname "$0")/.."

SNAPSHOT_LANGUAGE="en"
THEME_SUFFIX=""
for arg in "$@"; do
  case "$arg" in
    --dark) THEME_SUFFIX="-dark" ;;
    --language=*) SNAPSHOT_LANGUAGE="${arg#--language=}" ;;
    *) echo "usage: scripts/snapshot.sh [--dark] [--language=en|zh-Hans|zh-Hant]" >&2; exit 64 ;;
  esac
done
case "$SNAPSHOT_LANGUAGE" in
  en|zh-Hans|zh-Hant) ;;
  *) echo "unsupported snapshot language: $SNAPSHOT_LANGUAGE" >&2; exit 64 ;;
esac
OUT="${SSH_CAT_SNAPSHOT_ROOT:-build}/snapshots-$SNAPSHOT_LANGUAGE$THEME_SUFFIX"
BUILD_PATH="${SSH_CAT_SCRATCH_PATH:-.build}"
swift build --scratch-path "$BUILD_PATH"
BIN_DIR="$(swift build --scratch-path "$BUILD_PATH" --show-bin-path)"
rm -rf "$OUT"
"$BIN_DIR/SSHCat" --snapshot "$OUT" "$@"
