#!/usr/bin/env bash
# Shared helpers for talking to the resident notification agent.
#
# Transport is a spool directory: one JSON request per file, published by
# rename so the agent can never read a half-written request. That keeps every
# hook pure bash — no client binary to build, no socket lifetime to manage —
# and lets the integration test drive the whole agent by dropping files.
#
# Sourced, never executed. Callers must already have HOME set.

AGENT_ROOT="$HOME/.claude/notifications/ghostty-agent"
AGENT_SPOOL="$AGENT_ROOT/spool"
AGENT_PID_FILE="$AGENT_ROOT/agent.pid"
AGENT_BUNDLE_NAME="ClaudeGhosttyNotify.app"

# agent_app <hooks-dir>
# Prints the agent bundle path, or returns 1 when the agent is unavailable.
#
# An explicitly empty GHOSTTY_NOTIFY_AGENT_APP disables the agent and pins the
# shell delivery path — the `${VAR-default}` (no colon) form is deliberate, so
# "set but empty" is distinguishable from "unset". Tests rely on it.
agent_app() {
    local hooks_dir="${1:-}"
    if [[ -n "${GHOSTTY_NOTIFY_AGENT_APP+isset}" ]]; then
        [[ -n "$GHOSTTY_NOTIFY_AGENT_APP" ]] || return 1
        printf '%s' "$GHOSTTY_NOTIFY_AGENT_APP"
        return 0
    fi
    local candidate
    for candidate in \
        "$hooks_dir/../build/$AGENT_BUNDLE_NAME" \
        "$hooks_dir/$AGENT_BUNDLE_NAME" \
        "$HOME/.claude/hooks/$AGENT_BUNDLE_NAME"; do
        if [[ -x "$candidate/Contents/MacOS/ghostty-notify-agent" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

# agent_running
# True when the resident agent is alive. The command check guards against PID
# reuse: a recycled pid that is not our agent must not be mistaken for one, or
# requests would queue forever with nothing draining them.
agent_running() {
    local pid
    pid=$(cat "$AGENT_PID_FILE" 2>/dev/null) || return 1
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    ps -o command= -p "$pid" 2>/dev/null | grep -q 'ghostty-notify-agent'
}

# agent_send <json> <app-bundle>
# Queue one request, launching the agent if it is not up. Launch happens after
# the write so the request is already waiting: the agent drains the spool once
# at startup, which is also how requests written while it was down get served.
agent_send() {
    local json="$1" app="$2" name tmp
    mkdir -p "$AGENT_SPOOL" 2>/dev/null || return 1

    # Name sorts in arrival order, matching the agent's own writer format.
    # Second-granularity is enough: the agent drains on every directory change,
    # so two requests only share a batch if they landed milliseconds apart, and
    # within that window their order is genuinely ambiguous anyway.
    name=$(printf '%016d-%d.json' "$(( $(date +%s) * 1000 + RANDOM % 1000 ))" "$$")
    tmp="$AGENT_SPOOL/.$name.tmp"

    printf '%s' "$json" > "$tmp" 2>/dev/null || return 1
    mv -f "$tmp" "$AGENT_SPOOL/$name" 2>/dev/null || { rm -f "$tmp"; return 1; }

    agent_running || open -a "$app" 2>/dev/null || true
    return 0
}
