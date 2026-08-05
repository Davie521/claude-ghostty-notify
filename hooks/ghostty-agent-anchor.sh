#!/usr/bin/env bash
# UserPromptSubmit hook: tell the agent where this session lives, and withdraw
# anything still on screen for it.
#
# Submitting a prompt is the cheapest possible proof that the user is back at
# their terminal — free, exact, and it needs no polling. It also pins the
# session to a surface: the user just typed into their own tab, so whatever
# Ghostty reports as focused belongs to this session. That replaces the OSC-2
# marker round-trip (write a marker title, sleep, scan every tab, restore the
# title, under a lock) with one Apple Event inside a process that is already
# running.
#
# Anchor before dismiss: if the anchor is what teaches the agent this session's
# surface, the very first notification should already be localizable.

set -u
IFS=$'\n\t'

HOOK_DATA=""
if [[ ! -t 0 ]]; then
    HOOK_DATA=$(cat 2>/dev/null || true)
fi

command -v jq >/dev/null 2>&1 || exit 0
SESSION_ID=$(printf '%s' "$HOOK_DATA" | jq -r '.session_id // empty' 2>/dev/null)

# Same shape guard every hook applies before a session id reaches a path or a
# dictionary key.
[[ "$SESSION_ID" =~ ^[a-fA-F0-9-]+$ ]] || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
# shellcheck source=hooks/agent-common.sh
source "$SCRIPT_DIR/agent-common.sh" 2>/dev/null || exit 0

APP=$(agent_app "$SCRIPT_DIR") || exit 0

agent_send "$(jq -nc --arg s "$SESSION_ID" '{type:"anchor",session_id:$s}')" "$APP"
agent_send "$(jq -nc --arg s "$SESSION_ID" '{type:"dismiss",session_id:$s}')" "$APP"

exit 0
