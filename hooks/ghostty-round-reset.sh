#!/bin/bash
# Clear the round-start timestamp when the user submits a new prompt.
# Runs on UserPromptSubmit.
#
# The Stop hook clears the .start file at the end of a round, but Stop does
# NOT fire when the user interrupts a round (Esc/Ctrl-C) or the process
# dies. The stale timestamp would then survive into the next round and make
# its elapsed time — and therefore the notification tier and the "Finished
# after Xm Ys" text — wildly wrong. A new user prompt is always a round
# boundary, so clearing here re-arms the timer no matter how the previous
# round ended.

[[ "${TERM_PROGRAM:-}" != "ghostty" ]] && [[ -z "${GHOSTTY_RESOURCES_DIR:-}" ]] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

HOOK_DATA=""
if [[ ! -t 0 ]]; then
    HOOK_DATA=$(cat 2>/dev/null || true)
fi
[[ -z "$HOOK_DATA" ]] && exit 0

SESSION_ID=$(printf '%s' "$HOOK_DATA" | jq -r '.session_id // empty' 2>/dev/null)
[[ -z "$SESSION_ID" ]] && exit 0
[[ "$SESSION_ID" =~ ^[a-fA-F0-9-]+$ ]] || exit 0

rm -f "$HOME/.claude/notifications/ghostty-sessions/${SESSION_ID}.start"
exit 0
