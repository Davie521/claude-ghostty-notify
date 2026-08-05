#!/usr/bin/env bash
# Integration test for the resident notification agent.
#
# Drives the REAL binary through the REAL spool transport, using the same
# hooks/agent-common.sh helpers the hooks use, and asserts against the agent's
# own state file and log.
#
# What this deliberately does NOT assert: that a banner appeared. Notification
# delivery needs an authorization grant that only a human can give, so a test
# that depended on it would be unrunnable in CI. The rules that decide WHICH
# notification to withdraw are covered by the NotifyCore suites
# (`swift test --package-path agent`); what is left for a human is the manual
# smoke test — switch away, switch back, watch the banner go.
#
# Anti-false-green: a missing binary is FATAL, not a skip; the agent must prove
# it started (pidfile + log line) before any other assertion runs; and every
# assertion names the exact string it expects rather than "non-empty".

set -u
IFS=$'\n\t'

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
APP="${GHOSTTY_NOTIFY_AGENT_APP:-$REPO/build/ClaudeGhosttyNotify.app}"
BIN="$APP/Contents/MacOS/ghostty-notify-agent"

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }

# A skipped run must never look like a passing one. The agent is an AppKit app;
# without an Aqua session NSApplication cannot come up at all.
if [[ "$(launchctl managername 2>/dev/null)" != "Aqua" ]]; then
    echo "SKIP: no Aqua session — the agent needs a window server."
    echo "      NotifyCore unit tests remain the gate in this environment."
    exit 0
fi

if [[ ! -x "$BIN" ]]; then
    echo "FATAL: $BIN missing. Build it first:" >&2
    echo "  bash scripts/build-agent.sh" >&2
    exit 2
fi

SANDBOX=$(mktemp -d)
AGENT_PID=""
cleanup() {
    [[ -n "$AGENT_PID" ]] && kill "$AGENT_PID" 2>/dev/null
    rm -rf "$SANDBOX"
}
trap cleanup EXIT

export HOME="$SANDBOX"
ROOT="$HOME/.claude/notifications/ghostty-agent"
STATE="$ROOT/state.json"
LOG="$ROOT/agent.log"

# The helpers under test. They read HOME, so source after exporting it.
# shellcheck source=hooks/agent-common.sh
source "$REPO/hooks/agent-common.sh"

pass=0; fail=0
fail_list=()

check() {
    local label="$1"; shift
    if "$@"; then
        printf '  \033[32mPASS\033[0m  %s\n' "$label"
        pass=$((pass + 1))
    else
        printf '  \033[31mFAIL\033[0m  %s\n' "$label"
        fail=$((fail + 1))
        fail_list+=("$label")
    fi
}

# wait_for <seconds> <command...> — poll until the predicate holds.
wait_for() {
    local limit="$1"; shift
    local i=0
    while (( i < limit * 10 )); do
        "$@" && return 0
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}

log_has() { grep -qF "$1" "$LOG" 2>/dev/null; }
state_outstanding() {
    # Prints the outstanding notification ids for a session, comma-joined.
    jq -r --arg s "$1" '(.sessions[$s].notificationIDs // []) | join(",")' \
        "$STATE" 2>/dev/null
}
spool_drained() {
    local remaining
    remaining=$(find "$ROOT/spool" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
    [[ "$remaining" == "0" ]]
}

echo "== resident agent integration test =="

SID="deadbeef-1111-2222-3333-444455556666"
OTHER="deadbeef-9999"

# ── 1. The agent starts and claims its pidfile ─────────────────────────────
"$BIN" >/dev/null 2>&1 &
AGENT_PID=$!
check "agent starts and writes a pidfile" \
    wait_for 15 test -f "$ROOT/agent.pid"
check "agent logs its bundle identity (proves it is bundled, not a bare binary)" \
    wait_for 15 log_has "bundle=io.github.davie521.claude-ghostty-notify"

# Everything below is meaningless if the agent is not actually draining, so
# establish that first with a request whose only effect is a log line.
agent_send '{"type":"ping"}' "$APP"
check "spool transport delivers (ping answered)" wait_for 10 log_has "pong"
check "consumed request files are removed" wait_for 10 spool_drained

# ── 2. notify records an identifier ────────────────────────────────────────
agent_send "$(jq -nc --arg s "$SID" \
    '{type:"notify",session_id:$s,title:"Claude ✅",subtitle:"sub",body:"done",sound:"Glass"}')" \
    "$APP"
check "notify posts and records claude-<session>-1" \
    wait_for 10 log_has "posted claude-$SID-1"
check "state.json lists the identifier as outstanding" \
    wait_for 10 test "$(state_outstanding "$SID")" = "claude-$SID-1"

# ── 3. A second session's notification is tracked separately ───────────────
agent_send "$(jq -nc --arg s "$OTHER" '{type:"notify",session_id:$s,title:"other"}')" "$APP"
check "a second session gets its own identifier" \
    wait_for 10 test "$(state_outstanding "$OTHER")" = "claude-$OTHER-2"

# ── 4. dismiss withdraws only the session it names ─────────────────────────
agent_send "$(jq -nc --arg s "$SID" '{type:"dismiss",session_id:$s}')" "$APP"
check "dismiss withdraws the named session's notification" \
    wait_for 10 log_has "withdrew claude-$SID-1"
check "dismissed session has nothing outstanding" \
    wait_for 10 test "$(state_outstanding "$SID")" = ""
# The bug this guards: a dismiss that clears every session would silently
# destroy a sibling session's still-unread notification.
check "the other session's notification survives" \
    test "$(state_outstanding "$OTHER")" = "claude-$OTHER-2"

# ── 5. anchor is recorded ──────────────────────────────────────────────────
# Ghostty may not be running here, in which case the surface stays unknown —
# that is a legitimate outcome and the log records which one happened.
agent_send "$(jq -nc --arg s "$SID" '{type:"anchor",session_id:$s}')" "$APP"
check "anchor is processed" wait_for 10 log_has "anchored $SID -> "

# ── 6. Garbage does not wedge the drain ────────────────────────────────────
# A poison file is unlinked before it is decoded, so it must be dropped once and
# never retried — and the next good request must still be served.
agent_send 'not json at all' "$APP"
agent_send "$(jq -nc --arg s "../escape" '{type:"notify",session_id:$s,title:"evil"}')" "$APP"
agent_send '{"type":"selfDestruct"}' "$APP"
check "malformed requests are dropped, not retried" wait_for 10 spool_drained
agent_send '{"type":"ping"}' "$APP"
check "the agent still serves requests after garbage" \
    wait_for 10 test "$(grep -cF pong "$LOG")" -ge 2
# A rejected session id must not have created a record.
check "an invalid session id creates no state" \
    test "$(jq -r '.sessions | has("../escape")' "$STATE" 2>/dev/null)" = "false"

# ── 7. State survives a restart without reusing identifiers ────────────────
kill "$AGENT_PID" 2>/dev/null
wait "$AGENT_PID" 2>/dev/null || true
AGENT_PID=""
"$BIN" >/dev/null 2>&1 &
AGENT_PID=$!
check "restarted agent reloads its sessions" wait_for 15 log_has "restored "
agent_send "$(jq -nc --arg s "$SID" '{type:"notify",session_id:$s,title:"after restart"}')" "$APP"
# Reusing claude-<session>-1 here would collide with a notification that may
# still be on screen from before the restart.
check "identifiers are not reused after a restart" \
    wait_for 10 test "$(state_outstanding "$SID")" = "claude-$SID-3"

echo
echo "Results: $pass passed, $fail failed"
if (( fail > 0 )); then
    echo "Failed: ${fail_list[*]}"
    exit 1
fi
exit 0
