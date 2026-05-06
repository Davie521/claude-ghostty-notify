#!/bin/bash
# Ghostty-native notification for Claude Code.
# Wired up to the Stop hook only — Notification (idle/permission) events are
# intentionally not handled here; under bypass-permissions mode they're rare,
# and the terminal bell already fires when they do.
#
# Features:
#   - Only notify when the round has been running ≥ MIN_ELAPSED seconds
#   - Click notification → ghostty-tab-focus.sh jumps to the right tab
#   - System Glass sound for tasks past SOUND_ELAPSED
#   - Simple rate limit to prevent duplicate pings from sub-agents
#
# Backend dependency checks (terminal-notifier / alerter) live inside each
# fire_with_* function so a forced backend isn't silently blocked by a missing
# fallback dependency.

[[ "${TERM_PROGRAM:-}" != "ghostty" ]] && [[ -z "${GHOSTTY_RESOURCES_DIR:-}" ]] && exit 0
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
MIN_ELAPSED="${GHOSTTY_NOTIFY_MIN_ELAPSED:-180}"
SOUND_ELAPSED="${GHOSTTY_NOTIFY_SOUND_ELAPSED:-600}"
NOTIFY_TIMEOUT="${GHOSTTY_NOTIFY_TIMEOUT:-1200}"

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

# Stop event only — apply two-tier elapsed gating. Notification events are
# not registered to this script (see hooks.json / README).
case "$HOOK_EVENT" in
    Stop|stop) ;;
    *) clear_start_on_stop; exit 0 ;;
esac
if [[ "$START" -le 0 ]] || (( ELAPSED < MIN_ELAPSED )); then
    clear_start_on_stop
    exit 0
fi
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

# ── Build title/subtitle/sound (Stop only) ─────────────────────────────────
TITLE="Claude ✅"
SUBTITLE="Task Complete — $PROJECT_NAME"
MESSAGE=$(printf 'Finished after %dm %ds' $((ELAPSED / 60)) $((ELAPSED % 60)))
SOUND="Glass"

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
    [[ -x "$ALERTER" ]] || return 0
    # alerter returns click events ONLY via --actions (clicking the body just
    # activates the sender). So we give an explicit "Go to tab" button.
    # Omit --sound when SILENT=true (short-but-not-trivial tasks).
    local sound_args=()
    [[ "$SILENT" != "true" ]] && sound_args=(--sound "$SOUND")
    # Whitelist jump triggers. alerter 26.5+ returns the close-label text
    # ("Dismiss") instead of @CLOSED when the close button is used, so
    # blacklisting sentinels isn't safe. Fire focus ONLY when the user
    # either clicked the "Go to tab" action button, or clicked the
    # notification body itself (alerter reports @CONTENTCLICKED).
    # Keep ACTION_LABEL and --actions in sync.
    local ACTION_LABEL="Go to tab"
    (
        action=$("$ALERTER" \
            --title "$TITLE" \
            --subtitle "$SUBTITLE" \
            --message "$MESSAGE" \
            "${sound_args[@]}" \
            --group "$GROUP_ID" \
            --actions "$ACTION_LABEL" \
            --timeout "$NOTIFY_TIMEOUT" \
            --close-label "Dismiss" 2>/dev/null)
        case "$action" in
            "$ACTION_LABEL"|@CONTENTCLICKED)
                [[ -x "$FOCUS_SCRIPT" ]] && "$FOCUS_SCRIPT" "$SESSION_ID"
                ;;
        esac
    ) </dev/null >/dev/null 2>&1 &
    disown
}

fire_with_terminal_notifier() {
    command -v terminal-notifier >/dev/null 2>&1 || return 0
    # Click-to-jump: terminal-notifier's -execute fires on ANY click (including
    # dismiss). That's a tradeoff — dismissing a notification will also raise
    # the target Ghostty window. Acceptable cost for users on the
    # terminal-notifier backend (typically because their Script Editor bundle
    # isn't authorized for notifications, so alerter's UI silently fails).
    #
    # SESSION_ID is interpolated into a shell command string. To prevent shell
    # injection from a malicious hook payload, only wire up -execute when
    # SESSION_ID matches the UUID-like shape Claude Code emits. Anything else
    # falls back to plain notification with no click action.
    local args=(
        -title "$TITLE"
        -subtitle "$SUBTITLE"
        -message "$MESSAGE"
        -group "$GROUP_ID"
    )
    [[ "$SILENT" != "true" ]] && args+=(-sound "$SOUND")
    if [[ -x "$FOCUS_SCRIPT" ]] && [[ "$SESSION_ID" =~ ^[a-fA-F0-9-]+$ ]]; then
        args+=(-execute "$FOCUS_SCRIPT $SESSION_ID")
    fi
    terminal-notifier "${args[@]}" >/dev/null 2>&1
}

# Backend selection. Default: prefer alerter (supports click-to-jump), fall
# back to terminal-notifier. Override with GHOSTTY_NOTIFY_BACKEND:
#   - "terminal-notifier" : force terminal-notifier (use this when Script
#                           Editor's bundle isn't authorized for notifications
#                           in System Settings, since alerter borrows that
#                           bundle and silently fails to display)
#   - "alerter"           : force alerter (errors if missing)
#   - unset / "auto"      : prefer alerter, fall back to terminal-notifier
BACKEND="${GHOSTTY_NOTIFY_BACKEND:-auto}"
case "$BACKEND" in
    terminal-notifier)
        fire_with_terminal_notifier
        ;;
    alerter)
        fire_with_alerter
        ;;
    *)
        if [[ -x "$ALERTER" ]]; then
            fire_with_alerter
        else
            fire_with_terminal_notifier
        fi
        ;;
esac

clear_start_on_stop
exit 0
