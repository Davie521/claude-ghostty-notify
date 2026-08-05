#!/usr/bin/env bash
# Make the notification agent resident via a launchd LaunchAgent.
#
# Why launchd rather than "let the first hook start it": launchd restarts the
# agent if it ever crashes, starts it at login without waiting for a hook, and
# gives it a stable place to be stopped from. The hooks can still start it on
# demand (see hooks/agent-common.sh) so a machine without the LaunchAgent
# installed still works — this just removes the cold-start latency on the first
# notification after login.
#
# The plist is generated rather than committed because ProgramArguments needs the
# absolute path of wherever the bundle actually landed.
#
# Usage:
#   bash scripts/install-agent.sh              install and start
#   bash scripts/install-agent.sh --uninstall  stop and remove

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)

LABEL="io.github.davie521.claude-ghostty-notify"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="$REPO/build/ClaudeGhosttyNotify.app"
BIN="$APP/Contents/MacOS/ghostty-notify-agent"
DOMAIN="gui/$(id -u)"

unload() {
    # bootout fails when nothing is loaded; that is the normal case on a fresh
    # install, so it must not abort the script.
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
}

if [[ "${1:-}" == "--uninstall" ]]; then
    unload
    rm -f "$PLIST"
    echo "==> Removed $LABEL"
    exit 0
fi

[[ -x "$BIN" ]] || {
    echo "FATAL: $BIN missing. Build it first:" >&2
    echo "  bash scripts/build-agent.sh" >&2
    exit 2
}

mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <!-- The binary INSIDE the bundle, not \`open -a\`: launchd needs a process
         that stays alive, and \`open\` exits immediately. Running the bundled
         executable directly still resolves the bundle identity that
         UNUserNotificationCenter requires — verified by tests/test-agent.sh,
         which launches it exactly this way. -->
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
PLIST_EOF

unload
launchctl bootstrap "$DOMAIN" "$PLIST"

echo "==> Installed $LABEL"
echo "    plist: $PLIST"
echo "    stop:  bash scripts/install-agent.sh --uninstall"
echo
echo "On first notification macOS will ask twice:"
echo "  1. permission to send notifications"
echo "  2. permission to control Ghostty (needed for click-to-jump)"
echo "Both are one-time and both must be allowed."
