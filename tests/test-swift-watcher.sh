#!/usr/bin/env bash
# Integration test for the native clear-on-focus watcher (watcher/).
#
# The Swift binary replaces the bash watch loop wholesale, so it has to
# reproduce that loop's observable behaviour exactly. This file is the
# cross-language contract:
#   - exact-tab watch clears only when the session's tab is selected in the
#     frontmost window; app-level fallback needs a rising edge, and an
#     "unknown" frontmost must not arm that edge
#   - the watcher must not clear before the notification is delivered
#   - supersession claims the pidfile and leaves the successor trackable
#     (the predecessor must NOT delete it on the way out)
#   - the bash immediate-clear path can still identify and kill it, i.e. the
#     PID/argv contract that kill_if_matches depends on survives the rewrite
#   - the alerter dialect probe is honoured in BOTH directions, and clearing
#     removes the alerter pidfile
#
# Anti-false-green measures, because "the bash watcher quietly did the work"
# would otherwise look identical to success:
#   - GHOSTTY_NOTIFY_WATCHER_BIN is pinned at the release build, so the
#     hand-off cannot fall back to bash; a missing binary is FATAL, not a skip
#   - a discriminator assertion reads `ps -o command=` for the recorded
#     watch-pid and demands the "-watcher" suffix, which the bash watcher's
#     command line (`bash .../ghostty-notify-clear.sh --watch`) never has
#   - the lsappinfo stub is pinned to a non-Ghostty bundle, so even on a
#     developer machine running these tests inside Ghostty the bash watcher
#     could never satisfy a single clear assertion
#
# All external surfaces are stubbed: alerter (GNU and legacy dialects; both
# block like the real alert-style binary), terminal-notifier, lsappinfo,
# osascript. Frontmost state reaches the native watcher through its
# GHOSTTY_NOTIFY_WATCHER_FRONT_FILE test hook, which stands in for the
# frontmost-app query CI has no way to drive.

set -u
IFS=$'\n\t'

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
HOOK="$REPO/hooks/ghostty-notify.sh"
CLEAR="$REPO/hooks/ghostty-notify-clear.sh"
RESET="$REPO/hooks/ghostty-round-reset.sh"
WATCHER="$REPO/watcher/.build/release/ghostty-notify-clear-watcher"

for f in "$HOOK" "$CLEAR" "$RESET"; do
    [[ -x "$f" ]] || { echo "FATAL: $f not executable" >&2; exit 2; }
done
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
[[ -x "$WATCHER" ]] || {
    echo "FATAL: $WATCHER missing." >&2
    echo "       Build it first: scripts/build-watcher.sh" >&2
    echo "       (or: swift build -c release --package-path watcher)" >&2
    exit 2
}

# Determinize the lookup: never depend on whatever happens to sit in
# hooks/bin. This is also what makes a bash fallback impossible.
export GHOSTTY_NOTIFY_WATCHER_BIN="$WATCHER"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

export HOME="$SANDBOX"
export PATH="$SANDBOX/bin:$PATH"
SESS_DIR="$HOME/.claude/notifications/ghostty-sessions"
CONTROL="$SANDBOX/control"
mkdir -p \
    "$HOME/.claude/hooks" \
    "$SESS_DIR" \
    "$HOME/.local/bin" \
    "$SANDBOX/bin" \
    "$CONTROL"

# Control files driving the stubs:
#   front-bundle  : bundle id the native watcher reads as frontmost; absent
#                   means "could not tell"
#   selected-tab  : tab id osascript reports as selected in the front window
#   removed       : append-only log of group removals, recorded WITH the flag
#                   so the dialect is observable
#   alerter-sleep : how long a fired alerter blocks (default 30s)

# alerter stub, GNU dialect: --help advertises both --close-label (which
# ghostty-notify.sh probes) and --remove (which the watcher probes).
cat > "$HOME/.local/bin/alerter" <<SH
#!/bin/bash
if [[ "\${1:-}" == "--help" ]]; then
    echo "usage: --title --subtitle --close-label --remove --group"
    exit 0
fi
if [[ "\${1:-}" == "--remove" ]]; then
    printf 'alerter:--remove:%s\n' "\$2" >> "$CONTROL/removed"
    exit 0
fi
sleep "\$(cat "$CONTROL/alerter-sleep" 2>/dev/null || echo 30)"
SH
chmod +x "$HOME/.local/bin/alerter"

# alerter stub, pre-26.2 dialect: single-dash flags only, and a --help text
# with neither --close-label nor --remove in it.
cat > "$HOME/.local/bin/alerter-legacy" <<SH
#!/bin/bash
if [[ "\${1:-}" == "--help" ]]; then
    echo "usage: alerter -title <title> -remove <group> -closeLabel <label>"
    exit 0
fi
if [[ "\${1:-}" == "-remove" ]]; then
    printf 'alerter:-remove:%s\n' "\$2" >> "$CONTROL/removed"
    exit 0
fi
sleep "\$(cat "$CONTROL/alerter-sleep" 2>/dev/null || echo 30)"
SH
chmod +x "$HOME/.local/bin/alerter-legacy"

ALERTER_GNU="$HOME/.local/bin/alerter"
ALERTER_LEGACY="$HOME/.local/bin/alerter-legacy"
export GHOSTTY_NOTIFY_ALERTER="$ALERTER_GNU"

# terminal-notifier stub: PATH-only discovery, mirroring `command -v` in the
# shell — the native watcher must NOT probe fixed locations for this one.
cat > "$SANDBOX/bin/terminal-notifier" <<SH
#!/bin/bash
if [[ "\${1:-}" == "-remove" ]]; then
    printf 'tn:-remove:%s\n' "\$2" >> "$CONTROL/removed"
fi
exit 0
SH
chmod +x "$SANDBOX/bin/terminal-notifier"

# lsappinfo stub, pinned to a non-Ghostty bundle on purpose: the native
# watcher never calls it, and a bash watcher that somehow took over would be
# told Ghostty is in the background forever and could not clear anything.
cat > "$SANDBOX/bin/lsappinfo" <<'SH'
#!/bin/bash
if [[ "${1:-}" == "front" ]]; then
    echo "ASN:stub:"
    exit 0
fi
printf '"CFBundleIdentifier"="com.example.not-ghostty"\n'
SH
chmod +x "$SANDBOX/bin/lsappinfo"

# osascript stub: "yes" iff the watcher's TARGET_TAB_ID matches the control
# file — same contract the bash watcher's AppleScript honours.
cat > "$SANDBOX/bin/osascript" <<SH
#!/bin/bash
sel=\$(cat "$CONTROL/selected-tab" 2>/dev/null)
if [[ -n "\${TARGET_TAB_ID:-}" && "\$TARGET_TAB_ID" == "\$sel" ]]; then
    echo yes
else
    echo no
fi
SH
chmod +x "$SANDBOX/bin/osascript"

# Focus stub, pinned so a stray dispatch can't run the real script.
cat > "$HOME/.claude/hooks/ghostty-tab-focus.sh" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$HOME/.claude/hooks/ghostty-tab-focus.sh"
export GHOSTTY_NOTIFY_FOCUS_SCRIPT="$HOME/.claude/hooks/ghostty-tab-focus.sh"

export TERM_PROGRAM=ghostty
export GHOSTTY_NOTIFY_MIN_ELAPSED=10
export GHOSTTY_NOTIFY_SOUND_ELAPSED=9999
export GHOSTTY_NOTIFY_TIMEOUT=20
export GHOSTTY_NOTIFY_BACKEND=auto
export GHOSTTY_NOTIFY_FOCUS_POLL=0.2
export GHOSTTY_NOTIFY_WATCHER_FRONT_FILE="$CONTROL/front-bundle"
unset GHOSTTY_RESOURCES_DIR || true
unset GHOSTTY_NOTIFY_CLEAR_ON_FOCUS || true
unset GHOSTTY_NOTIFY_CLEAR_SCRIPT || true

pass=0; fail=0
fail_list=()

ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail + 1)); fail_list+=("$1"); }

check() {  # $1: 0/1 result, $2: label
    if [[ "$1" -eq 0 ]]; then ok "$2"; else bad "$2"; fi
}

want() {  # $1: label, $2...: predicate command that must succeed
    local label="$1"; shift
    if "$@"; then ok "$label"; else bad "$label"; fi
}

# Predicates (kept as commands so their status is unambiguous).
is_set()     { [[ -n "${1:-}" ]]; }
file_holds() { [[ "$(cat "$1" 2>/dev/null)" == "$2" ]]; }

new_sid() { printf 'ab%s-%s' "$(date +%s)" "$RANDOM"; }

# Atomic so a tick can never observe a half-written control file (which would
# read as "unknown" and make the rising-edge cases flaky).
set_front() { printf '%s\n' "$1" > "$CONTROL/front.tmp"; mv "$CONTROL/front.tmp" "$CONTROL/front-bundle"; }
unset_front() { rm -f "$CONTROL/front-bundle" 2>/dev/null; return 0; }
set_tab() { printf '%s\n' "$1" > "$CONTROL/tab.tmp"; mv "$CONTROL/tab.tmp" "$CONTROL/selected-tab"; }

fire_notification() {  # $1: sid
    echo $(( $(date +%s) - 60 )) > "$SESS_DIR/$1.start"
    printf '{"session_id":"%s","cwd":"/tmp","hook_event_name":"Stop"}' "$1" \
        | "$HOOK" >/dev/null 2>&1
}

wait_for() {  # $1: max tries (x100ms), $2...: condition command
    local tries="$1"; shift
    local i=0
    while (( i < tries )); do
        "$@" && return 0
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}

removed_gnu()    { grep -qxF "alerter:--remove:ghostty-notify-$1" "$CONTROL/removed" 2>/dev/null; }
removed_legacy() { grep -qxF "alerter:-remove:ghostty-notify-$1" "$CONTROL/removed" 2>/dev/null; }
removed_tn()     { grep -qxF "tn:-remove:ghostty-notify-$1" "$CONTROL/removed" 2>/dev/null; }
no_removal_for() { ! grep -qF "ghostty-notify-$1" "$CONTROL/removed" 2>/dev/null; }
pid_alive()      { [[ "$1" =~ ^[0-9]+$ ]] && kill -0 "$1" 2>/dev/null; }
pid_dead()       { [[ "$1" =~ ^[0-9]+$ ]] && ! kill -0 "$1" 2>/dev/null; }
file_gone()      { [[ ! -f "$1" ]]; }

# THE discriminator. The bash watcher runs as `bash .../ghostty-notify-clear.sh
# --watch <sid>` — it can match "ghostty-notify-clear", but never the
# "-watcher" suffix. If this passes, the process under test really is Swift.
watcher_is_native() {  # $1: sid
    local pid cmd
    pid=$(cat "$SESS_DIR/$1.watch-pid" 2>/dev/null)
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    cmd=$(ps -o command= -p "$pid" 2>/dev/null)
    [[ "$cmd" == *ghostty-notify-clear-watcher* ]]
}

await_alerter_pid() {  # $1: sid
    wait_for 30 test -s "$SESS_DIR/$1.alerter-pid" || return 1
    cat "$SESS_DIR/$1.alerter-pid" 2>/dev/null
}

await_watch_pid() {  # $1: sid
    wait_for 30 test -s "$SESS_DIR/$1.watch-pid" || return 1
    cat "$SESS_DIR/$1.watch-pid" 2>/dev/null
}

tidy_session() {  # kill leftovers without polluting the removal log
    local pid
    for pid in $(cat "$SESS_DIR/$1.watch-pid" "$SESS_DIR/$1.alerter-pid" 2>/dev/null); do
        [[ "$pid" =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null
    done
    rm -f "$SESS_DIR/$1".{watch-pid,alerter-pid,json,start} 2>/dev/null
}

reset_control() {
    : > "$CONTROL/removed"
    echo 30 > "$CONTROL/alerter-sleep"
}
reset_control

echo "== native watcher tests =="

# ── Case 1: exact-tab watch clears when the session tab gains focus ────────
sid=$(new_sid)
printf '{"tab_id":"tab-42","cwd":"/tmp"}\n' > "$SESS_DIR/$sid.json"
set_front "com.other.app"
set_tab "tab-99"
fire_notification "$sid"

APID=$(await_alerter_pid "$sid")
want "alerter pidfile written on fire" is_set "$APID"
WPID=$(await_watch_pid "$sid")
want "watcher started on fire" is_set "$WPID"
check "$(watcher_is_native "$sid"; echo $?)" \
    "the running watcher is the native binary, not the bash loop"

sleep 0.6
check "$(no_removal_for "$sid"; echo $?)" "no clear while Ghostty is in background"

set_front "com.mitchellh.ghostty"
sleep 0.6
check "$(no_removal_for "$sid"; echo $?)" "no clear while a different tab is selected"

set_tab "tab-42"
wait_for 30 removed_gnu "$sid"
check $? "clears when the session tab becomes selected"
# Both backends are tried in turn, so the tn line lands just after the alerter
# one — wait for it rather than sampling the log mid-removal.
wait_for 20 removed_tn "$sid"
check $? "clear also removes the terminal-notifier group"
wait_for 20 pid_dead "$APID"
check $? "blocking alerter killed on clear"
wait_for 20 pid_dead "$WPID"
check $? "watcher exits after clearing"
check "$(file_gone "$SESS_DIR/$sid.alerter-pid"; echo $?)" \
    "clear removes the alerter pidfile"
tidy_session "$sid"
reset_control

# ── Case 2: app-level fallback needs a rising edge ─────────────────────────
sid=$(new_sid)   # no .json → tab unknown → fallback mode
set_front "com.mitchellh.ghostty"
set_tab ""
fire_notification "$sid"
want "fallback: notification fired" is_set "$(await_alerter_pid "$sid")"
await_watch_pid "$sid" >/dev/null
check "$(watcher_is_native "$sid"; echo $?)" "fallback: native watcher running"

sleep 0.8
check "$(no_removal_for "$sid"; echo $?)" "fallback: already-frontmost Ghostty does not clear"

# "Could not tell" is not "the user left Ghostty".
unset_front
sleep 0.8
set_front "com.mitchellh.ghostty"
sleep 0.6
check "$(no_removal_for "$sid"; echo $?)" "fallback: unknown frontmost does not arm the edge"

set_front "com.other.app"
sleep 0.6
set_front "com.mitchellh.ghostty"
wait_for 30 removed_gnu "$sid"
check $? "fallback: clears when Ghostty becomes frontmost again"
tidy_session "$sid"
reset_control

# ── Case 3: bash immediate-clear still reaches the native watcher ──────────
# kill_if_matches greps `ps -o command=` for "ghostty-notify-clear" AND the
# session id. The binary's name and argv are what keep that working.
sid=$(new_sid)
printf '{"tab_id":"tab-77","cwd":"/tmp"}\n' > "$SESS_DIR/$sid.json"
set_front "com.other.app"
set_tab "tab-1"
fire_notification "$sid"
APID=$(await_alerter_pid "$sid")
want "prompt submit: notification fired first" is_set "$APID"
WPID=$(await_watch_pid "$sid")
check "$(watcher_is_native "$sid"; echo $?)" "prompt submit: native watcher running before submit"

printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit"}' "$sid" \
    | "$RESET" >/dev/null 2>&1

wait_for 30 removed_gnu "$sid"
check $? "prompt submit: notification group removed"
wait_for 20 pid_dead "$APID"
check $? "prompt submit: blocking alerter killed"
wait_for 30 pid_dead "$WPID"
check $? "prompt submit: bash kill_if_matches reaches the native watcher"
tidy_session "$sid"
reset_control

# ── Case 4: supersession leaves the successor trackable ────────────────────
# The predecessor must claim-then-kill and never delete the pidfile on exit,
# or the successor runs untracked and can never be superseded or cleared.
sid=$(new_sid)
set_front "com.other.app"
set_tab "tab-1"
"$CLEAR" --watch "$sid" >/dev/null 2>&1 &
W1=$!
wait_for 30 sh -c "[[ \"\$(cat '$SESS_DIR/$sid.watch-pid' 2>/dev/null)\" == '$W1' ]]"
check $? "supersession: first native watcher claimed the slot"
check "$(pid_alive "$W1"; echo $?)" "supersession: first watcher running"

"$CLEAR" --watch "$sid" >/dev/null 2>&1 &
W2=$!
wait_for 30 sh -c "[[ \"\$(cat '$SESS_DIR/$sid.watch-pid' 2>/dev/null)\" == '$W2' ]]"
check $? "supersession: successor claimed the slot"
wait_for 30 pid_dead "$W1"
check $? "supersession: predecessor killed"
sleep 0.5
want "supersession: successor still tracked after predecessor exits" \
    file_holds "$SESS_DIR/$sid.watch-pid" "$W2"
kill "$W2" 2>/dev/null
tidy_session "$sid"
reset_control

# ── Case 5: no clear before the notification is delivered ──────────────────
# GHOSTTY_NOTIFY_EXPECT_ALERTER=1 says a pidfile is coming; clearing first
# would remove nothing and exit, leaving the real alert unwatched.
sid=$(new_sid)
printf '{"tab_id":"tab-33","cwd":"/tmp"}\n' > "$SESS_DIR/$sid.json"
set_front "com.mitchellh.ghostty"
set_tab "tab-33"
GHOSTTY_NOTIFY_EXPECT_ALERTER=1 "$CLEAR" --watch "$sid" >/dev/null 2>&1 &
W=$!
await_watch_pid "$sid" >/dev/null
sleep 1.2
check "$(no_removal_for "$sid"; echo $?)" "arming gate: no clear before delivery"
check "$(pid_alive "$W"; echo $?)" "arming gate: watcher keeps waiting"
kill "$W" 2>/dev/null
tidy_session "$sid"
reset_control

# ── Case 6: legacy alerter dialect ─────────────────────────────────────────
# A hard-coded --remove would pass every case above and silently fail for
# every pre-26.2 alerter, so assert the other direction explicitly.
sid=$(new_sid)
export GHOSTTY_NOTIFY_ALERTER="$ALERTER_LEGACY"
printf '{"tab_id":"tab-55","cwd":"/tmp"}\n' > "$SESS_DIR/$sid.json"
set_front "com.other.app"
set_tab "tab-1"
fire_notification "$sid"
want "legacy: notification fired" is_set "$(await_alerter_pid "$sid")"
await_watch_pid "$sid" >/dev/null

set_front "com.mitchellh.ghostty"
set_tab "tab-55"
wait_for 30 removed_legacy "$sid"
check $? "legacy dialect clears with single-dash -remove"
check "$(! removed_gnu "$sid"; echo $?)" "legacy dialect never sends --remove"
export GHOSTTY_NOTIFY_ALERTER="$ALERTER_GNU"
tidy_session "$sid"
reset_control

# ── Case 7: FOCUS_POLL=0 must not become a busy loop ───────────────────────
sid=$(new_sid)
printf '{"tab_id":"tab-88","cwd":"/tmp"}\n' > "$SESS_DIR/$sid.json"
set_front "com.other.app"
set_tab "tab-1"
GHOSTTY_NOTIFY_FOCUS_POLL=0 fire_notification "$sid"
await_alerter_pid "$sid" >/dev/null
WPID=$(await_watch_pid "$sid")
if [[ "$WPID" =~ ^[0-9]+$ ]]; then
    sleep 2
    CPU=$(ps -o %cpu= -p "$WPID" 2>/dev/null | tr -d ' ')
    CPU_INT=${CPU%%.*}
    [[ "$CPU_INT" =~ ^[0-9]+$ ]] || CPU_INT=0
    check "$(( CPU_INT < 25 ? 0 : 1 ))" "FOCUS_POLL=0 falls back to a paced poll (cpu=${CPU:-?}%)"
else
    bad "FOCUS_POLL=0 falls back to a paced poll (no watcher)"
fi
tidy_session "$sid"
reset_control

echo
echo "Results: $pass passed, $fail failed"
if (( fail > 0 )); then
    echo "Failed cases: ${fail_list[*]}"
    exit 1
fi
exit 0
