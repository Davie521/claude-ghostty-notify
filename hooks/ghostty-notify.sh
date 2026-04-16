#!/bin/bash
# Ghostty-native notification for Claude Code.
# Replaces code-notify for Notification/Stop hooks.
#
# Features:
#   - Only notify when the round has been running ≥ MIN_ELAPSED seconds
#   - Click notification → ghostty-tab-focus.sh jumps to the right tab
#   - System sound (Glass for Stop, Ping for input required)
#   - Simple rate limit to prevent duplicate pings from sub-agents

[[ "${TERM_PROGRAM:-}" != "ghostty" ]] && [[ -z "${GHOSTTY_RESOURCES_DIR:-}" ]] && exit 0
command -v terminal-notifier >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

HOOK_DATA=""
if [[ ! -t 0 ]]; then
    HOOK_DATA=$(cat 2>/dev/null || true)
fi
[[ -z "$HOOK_DATA" ]] && exit 0

SESSION_ID=$(printf '%s' "$HOOK_DATA" | jq -r '.session_id // empty' 2>/dev/null)
CWD=$(printf '%s' "$HOOK_DATA" | jq -r '.cwd // empty' 2>/dev/null)
HOOK_EVENT=$(printf '%s' "$HOOK_DATA" | jq -r '.hook_event_name // empty' 2>/dev/null)
[[ -z "$SESSION_ID" ]] && exit 0

SAVE_DIR="$HOME/.claude/notifications/ghostty-sessions"
START_FILE="$SAVE_DIR/${SESSION_ID}.start"

# ── Elapsed-time gates ────────────────────────────────────────────────────
# Two tiers:
#   MIN_ELAPSED   — below this: completely silent (no notification)
#   SOUND_ELAPSED — below this but above MIN: notification WITHOUT sound
#                   at/above: notification WITH sound
MIN_ELAPSED="${GHOSTTY_NOTIFY_MIN_ELAPSED:-60}"
SOUND_ELAPSED="${GHOSTTY_NOTIFY_SOUND_ELAPSED:-300}"
NOTIFY_TIMEOUT="${GHOSTTY_NOTIFY_TIMEOUT:-120}"

NOW=$(date +%s)
START=0
[[ -f "$START_FILE" ]] && START=$(cat "$START_FILE" 2>/dev/null || echo 0)
ELAPSED=$((NOW - START))

# On Stop, always clear the start marker so the next round re-arms.
clear_start_on_stop() {
    case "$HOOK_EVENT" in
        Stop|stop) rm -f "$START_FILE" ;;
    esac
}

# Below the MIN threshold → completely silent, skip notification.
if [[ "$START" -le 0 ]] || (( ELAPSED < MIN_ELAPSED )); then
    clear_start_on_stop
    exit 0
fi

# Between MIN and SOUND → notify silently (no audio).
SILENT=false
(( ELAPSED < SOUND_ELAPSED )) && SILENT=true

# ── Rate limit (avoid spam from parallel sub-agents) ──────────────────────
RATE_DIR="$HOME/.claude/notifications/state"
mkdir -p "$RATE_DIR"
PROJECT_NAME=$(basename "${CWD:-$PWD}")
RATE_KEY=$(printf '%s-%s-%s' "$HOOK_EVENT" "$SESSION_ID" "$PROJECT_NAME" | tr -c 'A-Za-z0-9._-' '_')
RATE_FILE="$RATE_DIR/ghostty-notify-$RATE_KEY"
RATE_WINDOW=10  # seconds
if [[ -f "$RATE_FILE" ]]; then
    LAST=$(cat "$RATE_FILE" 2>/dev/null || echo 0)
    (( NOW - LAST < RATE_WINDOW )) && { clear_start_on_stop; exit 0; }
fi
date +%s > "$RATE_FILE"

# ── Build title/subtitle/sound per event ───────────────────────────────────
case "$HOOK_EVENT" in
    Stop|stop)
        TITLE="Claude ✅"
        SUBTITLE="Task Complete — $PROJECT_NAME"
        MESSAGE=$(printf 'Finished after %dm %ds' $((ELAPSED / 60)) $((ELAPSED % 60)))
        SOUND="Glass"
        ;;
    Notification|notification)
        if printf '%s' "$HOOK_DATA" | grep -q 'permission_prompt\|request_permissions' 2>/dev/null; then
            TITLE="Claude 🔐"
            SUBTITLE="Permission Required — $PROJECT_NAME"
            MESSAGE=$(printf '%s' "$HOOK_DATA" | jq -r '.message // "Claude needs permission"' 2>/dev/null)
        else
            TITLE="Claude 🔔"
            SUBTITLE="Input Required — $PROJECT_NAME"
            MESSAGE=$(printf '%s' "$HOOK_DATA" | jq -r '.message // "Claude is waiting for you"' 2>/dev/null)
        fi
        SOUND="Ping"
        ;;
    *)
        clear_start_on_stop
        exit 0
        ;;
esac

# ── Fire notification with click-to-focus ──────────────────────────────────
# Use `alerter` (already installed at ~/.local/bin/alerter) instead of
# terminal-notifier. `alerter` is always alert-style, so clicks reliably
# trigger the focus action on modern macOS (Banner-style terminal-notifier
# notifications silently drop -execute clicks).
#
# alerter blocks until the user clicks or timeout — we fire-and-forget via
# backgrounded subshell + disown so the hook returns immediately.

FOCUS_SCRIPT="$HOME/.claude/hooks/ghostty-tab-focus.sh"
ALERTER="$HOME/.local/bin/alerter"
GROUP_ID="ghostty-notify-${SESSION_ID}"

fire_with_alerter() {
    # alerter returns click events ONLY via --actions (clicking the body just
    # activates the sender). So we give an explicit "Go to tab" button.
    # Omit --sound when SILENT=true (short-but-not-trivial tasks).
    local sound_args=()
    [[ "$SILENT" != "true" ]] && sound_args=(--sound "$SOUND")
    (
        action=$("$ALERTER" \
            --title "$TITLE" \
            --subtitle "$SUBTITLE" \
            --message "$MESSAGE" \
            "${sound_args[@]}" \
            --group "$GROUP_ID" \
            --actions "Go to tab" \
            --timeout "$NOTIFY_TIMEOUT" \
            --close-label "Dismiss" 2>/dev/null)
        case "$action" in
            @CLOSED|@TIMEOUT|"") ;;  # dismissed / ignored → do nothing
            *) [[ -x "$FOCUS_SCRIPT" ]] && "$FOCUS_SCRIPT" "$SESSION_ID" ;;
        esac
    ) </dev/null >/dev/null 2>&1 &
    disown
}

fire_with_terminal_notifier() {
    # Fallback if alerter is missing — relies on user's notification style
    # being "Alerts" for click-through to work.
    local args=(
        -title "$TITLE"
        -subtitle "$SUBTITLE"
        -message "$MESSAGE"
        -group "$GROUP_ID"
    )
    [[ "$SILENT" != "true" ]] && args+=(-sound "$SOUND")
    if [[ -x "$FOCUS_SCRIPT" ]]; then
        args+=(-execute "$FOCUS_SCRIPT $SESSION_ID")
    else
        args+=(-activate "com.mitchellh.ghostty")
    fi
    terminal-notifier "${args[@]}" >/dev/null 2>&1
}

if [[ -x "$ALERTER" ]]; then
    fire_with_alerter
else
    fire_with_terminal_notifier
fi

clear_start_on_stop
exit 0
