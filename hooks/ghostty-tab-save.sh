#!/bin/bash
# Save Ghostty tab info for this Claude session.
# Runs on PreToolUse — captures (once per session) the exact tab that hosts
# this Claude process using an OSC 2 marker round-trip:
#   1. Find Claude's TTY via process tree
#   2. Snapshot all Ghostty tab titles
#   3. Write a unique marker via OSC 2 to Claude's TTY
#   4. Query Ghostty for the tab whose title is the marker — that's us
#   5. Write the original title back via OSC 2 to clean up

[[ "${TERM_PROGRAM:-}" != "ghostty" ]] && [[ -z "${GHOSTTY_RESOURCES_DIR:-}" ]] && exit 0

HOOK_DATA=""
if [[ ! -t 0 ]]; then
    HOOK_DATA=$(cat 2>/dev/null || true)
fi
[[ -z "$HOOK_DATA" ]] && exit 0

command -v jq >/dev/null 2>&1 || exit 0

SESSION_ID=$(printf '%s' "$HOOK_DATA" | jq -r '.session_id // empty' 2>/dev/null)
CWD=$(printf '%s' "$HOOK_DATA" | jq -r '.cwd // empty' 2>/dev/null)
[[ -z "$SESSION_ID" ]] && exit 0

SAVE_DIR="$HOME/.claude/notifications/ghostty-sessions"
SAVE_FILE="$SAVE_DIR/${SESSION_ID}.json"
START_FILE="$SAVE_DIR/${SESSION_ID}.start"
mkdir -p "$SAVE_DIR"

# Record task start time only if not already set. Stop hook deletes this file,
# so next PreToolUse creates a fresh timestamp at the start of each new round.
[[ -f "$START_FILE" ]] || date +%s > "$START_FILE"

# Skip tab-id resolution if already saved for this session.
[[ -f "$SAVE_FILE" ]] && exit 0

# ── Locate Claude's controlling TTY ────────────────────────────────────────
find_claude_tty() {
    local pid=$$
    local depth=10
    while (( depth-- > 0 )) && [[ "$pid" -gt 1 ]]; do
        local parent
        parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        [[ -z "$parent" || "$parent" -le 1 ]] && break
        local cmd
        cmd=$(ps -o command= -p "$parent" 2>/dev/null)
        case "$cmd" in
            claude|claude\ *|*/claude|*/claude\ *)
                local tty
                tty=$(ps -o tty= -p "$parent" 2>/dev/null | tr -d ' ')
                [[ -n "$tty" && "$tty" != "??" ]] && printf '/dev/%s\n' "$tty"
                return
                ;;
        esac
        pid="$parent"
    done
    return 1
}

TTY_PATH=$(find_claude_tty)
[[ -z "$TTY_PATH" ]] && exit 0
[[ -w "$TTY_PATH" ]] || exit 0

MARKER="__CLAUDE_TAB_MARKER_${SESSION_ID}__"
TAB_ID=""
MARKER_WRITTEN=0

# ── Snapshot all tab titles BEFORE marker ──────────────────────────────────
SNAPSHOT=$(osascript <<'APPLESCRIPT' 2>/dev/null
tell application "Ghostty"
    set out to ""
    repeat with w in every window
        repeat with t in every tab of w
            try
                set out to out & (id of t) & "\t" & (name of t) & linefeed
            end try
        end repeat
    end repeat
    return out
end tell
APPLESCRIPT
)

# Always attempt restore on exit, even on error. Re-queries Ghostty for any
# tab still showing the marker (covers the case where our primary resolve
# failed but the title is stuck). This makes M1+M2 bulletproof.
restore_marker_title() {
    [[ $MARKER_WRITTEN -eq 0 ]] && return 0
    local target="$TAB_ID"
    if [[ -z "$target" ]]; then
        target=$(MARKER="$MARKER" osascript <<'APPLESCRIPT' 2>/dev/null
set targetMarker to (system attribute "MARKER")
tell application "Ghostty"
    repeat with w in every window
        repeat with t in every tab of w
            try
                if (name of t as text) is targetMarker then
                    return id of t
                end if
            end try
        end repeat
    end repeat
    return ""
end tell
APPLESCRIPT
        )
    fi
    [[ -z "$target" ]] && return 0
    local orig
    orig=$(printf '%s' "$SNAPSHOT" | awk -F'\t' -v id="$target" '$1 == id { print $2; exit }')
    [[ -z "$orig" ]] && orig="Claude Code"
    printf '\033]2;%s\033\\' "$orig" > "$TTY_PATH" 2>/dev/null
}
trap restore_marker_title EXIT

# ── Fire OSC 2 marker ───────────────────────────────────────────────────────
printf '\033]2;%s\033\\' "$MARKER" > "$TTY_PATH" 2>/dev/null
MARKER_WRITTEN=1

# Small delay so Ghostty processes the escape and updates AppleScript state
sleep 0.15

# ── Find the tab whose title is now our marker ──────────────────────────────
# Pass marker via env; AppleScript reads it via `system attribute` which IS
# inherited when osascript itself runs under the env.
TAB_ID=$(MARKER="$MARKER" osascript <<'APPLESCRIPT' 2>/dev/null
set targetMarker to (system attribute "MARKER")
tell application "Ghostty"
    repeat with w in every window
        repeat with t in every tab of w
            try
                if (name of t as text) is targetMarker then
                    return id of t
                end if
            end try
        end repeat
    end repeat
    return ""
end tell
APPLESCRIPT
)

# Trap will restore title on exit — unconditionally, even if TAB_ID is empty.
[[ -z "$TAB_ID" ]] && exit 0

printf '{"tab_id":%s,"cwd":%s}\n' \
    "$(printf '%s' "$TAB_ID" | jq -Rs .)" \
    "$(printf '%s' "$CWD" | jq -Rs .)" \
    > "$SAVE_FILE"

find "$SAVE_DIR" -type f -name '*.json' -mtime +7 -delete 2>/dev/null

exit 0
