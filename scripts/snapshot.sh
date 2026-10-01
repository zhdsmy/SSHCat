#!/bin/bash
# Debug-only UI previews: temporary rules and fake ssh; never load the user's data.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="build/snapshots"
for arg in "$@"; do
  [[ "$arg" != "--dark" ]] || OUT="build/snapshots-dark"
done
swift build
rm -rf "$OUT"
.build/debug/SSHCat --snapshot "$OUT" "$@"
