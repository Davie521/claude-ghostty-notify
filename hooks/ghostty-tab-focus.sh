#!/bin/bash
# Focus the Ghostty tab associated with a Claude session.
# Called by terminal-notifier -execute when the user clicks a notification.
# Arg $1: Claude session_id

SESSION_ID="${1:-}"

# Always bring Ghostty to front (degraded behavior if we can't find the tab)
osascript -e 'tell application "Ghostty" to activate' 2>/dev/null

[[ -z "$SESSION_ID" ]] && exit 0

SAVE_DIR="$HOME/.claude/notifications/ghostty-sessions"
SAVE_FILE="$SAVE_DIR/${SESSION_ID}.json"
[[ -f "$SAVE_FILE" ]] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

TAB_ID=$(jq -r '.tab_id // empty' "$SAVE_FILE" 2>/dev/null)
[[ -z "$TAB_ID" ]] && exit 0

# Find the tab across all windows and select it
osascript <<APPLESCRIPT 2>/dev/null
set targetId to "$TAB_ID"
tell application "Ghostty"
    repeat with w in every window
        repeat with t in every tab of w
            if (id of t as text) is targetId then
                select tab t
                return
            end if
        end repeat
    end repeat
end tell
APPLESCRIPT

exit 0
