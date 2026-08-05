#!/usr/bin/env bash
# Build the resident notification agent and assemble it into an .app bundle.
#
# The bundle is not optional packaging: UNUserNotificationCenter refuses to
# serve a process with no bundle identity, and macOS refuses to grant
# notification authorization at all to a bundle living in a temporary directory
# (verified — a bundle under /private/tmp gets an immediate
# "Notifications are not allowed for this application"). So the bundle is
# assembled under the repo, which is a stable, user-owned location.
#
# Nothing here is committed: see .gitignore.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)

APP="$REPO/build/ClaudeGhosttyNotify.app"
CONTENTS="$APP/Contents"
BINARY_NAME="ghostty-notify-agent"

command -v swift >/dev/null 2>&1 || {
    echo "FATAL: swift not found. Install Xcode or the Command Line Tools:" >&2
    echo "  xcode-select --install" >&2
    exit 2
}

echo "==> Building $BINARY_NAME (release)"
swift build -c release --package-path "$REPO/agent"
BUILT=$(swift build -c release --package-path "$REPO/agent" --show-bin-path)/"$BINARY_NAME"
[[ -x "$BUILT" ]] || { echo "FATAL: $BUILT missing after build" >&2; exit 2; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
install -m 755 "$BUILT" "$CONTENTS/MacOS/$BINARY_NAME"
install -m 644 "$REPO/agent/Resources/Info.plist" "$CONTENTS/Info.plist"

# Borrow Claude's icon so the notification looks like it came from Claude rather
# than from a generic binary. Purely cosmetic — a missing icon is not an error.
for icon in \
    "/Applications/Claude.app/Contents/Resources/AppIcon.icns" \
    "$HOME/Applications/Claude.app/Contents/Resources/AppIcon.icns"; do
    if [[ -f "$icon" ]]; then
        install -m 644 "$icon" "$CONTENTS/Resources/AppIcon.icns"
        break
    fi
done

# TCC keys its notification and Automation grants to the code signature, so sign
# explicitly rather than relying on the linker's implicit ad-hoc signature.
# Re-signing an unchanged binary keeps the same identity; changing the binary
# does not, which is why a rebuild can re-prompt for permission.
echo "==> Signing (ad-hoc)"
codesign --sign - --force --timestamp=none "$APP" >/dev/null 2>&1 ||
    echo "  warning: codesign failed; the linker's implicit signature will have to do" >&2

# Register with LaunchServices so `open -a` and notification delivery resolve
# the bundle without waiting for a periodic rescan.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[[ -x "$LSREGISTER" ]] && "$LSREGISTER" -f "$APP"

echo "==> Built $APP"
