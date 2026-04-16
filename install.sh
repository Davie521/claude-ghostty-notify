#!/bin/bash
# Installer for claude-ghostty-notify.
# Copies the three hook scripts into ~/.claude/hooks/ and prints the
# settings.json snippet to merge into the user's config.

set -eu

if [[ "$(uname)" != "Darwin" ]]; then
    echo "❌ macOS only (Ghostty AppleScript-based)." >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "❌ Missing dependency: jq"
    echo "   Install:  brew install jq"
    exit 1
fi

ALERTER="$HOME/.local/bin/alerter"
if [[ ! -x "$ALERTER" ]] && ! command -v alerter >/dev/null 2>&1; then
    echo "⚠️  Missing recommended dependency: alerter"
    echo "   Install:  brew install alerter"
    echo "   (hooks will still install, but notifications fall back to terminal-notifier)"
fi

# Resolve the source hooks dir.
# If the script is run from a local git checkout, use that.
# Otherwise (curl | bash path), download from GitHub.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd 2>/dev/null || echo '')"
LOCAL_HOOKS="$SCRIPT_DIR/hooks"

HOOKS_DIR="$HOME/.claude/hooks"
mkdir -p "$HOOKS_DIR"

install_from_local() {
    for f in ghostty-tab-save.sh ghostty-tab-focus.sh ghostty-notify.sh; do
        cp "$LOCAL_HOOKS/$f" "$HOOKS_DIR/$f"
        chmod +x "$HOOKS_DIR/$f"
        echo "  ✓ installed $f (local)"
    done
}

install_from_github() {
    local RAW="https://raw.githubusercontent.com/Davie521/claude-ghostty-notify/main/hooks"
    for f in ghostty-tab-save.sh ghostty-tab-focus.sh ghostty-notify.sh; do
        curl -fsSL "$RAW/$f" -o "$HOOKS_DIR/$f"
        chmod +x "$HOOKS_DIR/$f"
        echo "  ✓ installed $f (remote)"
    done
}

if [[ -d "$LOCAL_HOOKS" ]] && [[ -f "$LOCAL_HOOKS/ghostty-tab-save.sh" ]]; then
    echo "Installing hooks (local copy)..."
    install_from_local
else
    echo "Installing hooks (from GitHub)..."
    install_from_github
fi

echo
echo "─────────────────────────────────────────────────────────"
echo "Next steps:"
echo
echo "1. Merge the snippet into ~/.claude/settings.json:"
echo
cat <<'EOF'
    "env": {
      "GHOSTTY_NOTIFY_MIN_ELAPSED": "45",
      "GHOSTTY_NOTIFY_SOUND_ELAPSED": "120",
      "GHOSTTY_NOTIFY_TIMEOUT": "600"
    },
    "hooks": {
      "Notification": [{
        "matcher": "idle_prompt|permission_prompt",
        "hooks": [{"type": "command", "command": "/Users/$USER/.claude/hooks/ghostty-notify.sh"}]
      }],
      "PreToolUse": [{
        "matcher": "",
        "hooks": [{"type": "command", "command": "/Users/$USER/.claude/hooks/ghostty-tab-save.sh"}]
      }],
      "Stop": [{
        "matcher": "",
        "hooks": [{"type": "command", "command": "/Users/$USER/.claude/hooks/ghostty-notify.sh"}]
      }]
    }
EOF
echo
echo "   (Replace \$USER with your username — hooks require absolute paths.)"
echo
echo "2. System Settings → Notifications → Script Editor → Alert Style → Persistent"
echo
echo "3. Restart Claude Code so the env vars take effect."
echo "─────────────────────────────────────────────────────────"
