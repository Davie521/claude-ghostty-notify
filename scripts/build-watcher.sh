#!/usr/bin/env bash
# Build the native clear-on-focus watcher and drop it where
# hooks/ghostty-notify-clear.sh looks for it.
#
# The binary is not committed and install.sh does not ship it, so this is a
# developer convenience: run it and this checkout's hooks exec the native
# watcher; delete hooks/bin and they go straight back to the bash poll loop.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
BIN_NAME="ghostty-notify-clear-watcher"

command -v swift >/dev/null 2>&1 || {
    echo "FATAL: swift not found (install Xcode or the Swift toolchain)" >&2
    exit 2
}

# -c release is a requirement, not a preference: tests/test-swift-watcher.sh
# resolves the binary under .build/release, so a debug build leaves it FATAL.
swift build -c release --package-path "$REPO/watcher"

mkdir -p "$REPO/hooks/bin"
install -m 755 \
    "$REPO/watcher/.build/release/$BIN_NAME" \
    "$REPO/hooks/bin/$BIN_NAME"

printf 'installed %s\n' "$REPO/hooks/bin/$BIN_NAME"
