#!/usr/bin/env bash
# Make the notification agent resident via a launchd LaunchAgent.
#
# Why launchd rather than "let the first hook start it": launchd restarts the
# agent if it ever crashes, starts it at login without waiting for a hook, and
# gives it a stable place to be stopped from. The hooks can still start it on
# demand (see hooks/agent-common.sh) so a machine without the LaunchAgent
# installed still works — this just removes the cold-start latency on the first
# notification after login.
#
# The plist is generated rather than committed because ProgramArguments needs the
# absolute path of wherever the bundle actually landed.
#
# Usage:
#   bash scripts/install-agent.sh              install and start
#   bash scripts/install-agent.sh --uninstall  stop and remove

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)

LABEL="io.github.davie521.cgnotify"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="$REPO/build/ClaudeGhosttyNotify.app"
BIN="$APP/Contents/MacOS/ghostty-notify-agent"
DOMAIN="gui/$(id -u)"

unload() {
    # bootout fails when nothing is loaded; that is the normal case on a fresh
    # install, so it must not abort the script.
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
}

if [[ "${1:-}" == "--uninstall" ]]; then
    unload
    rm -f "$PLIST"
    echo "==> Removed $LABEL"
    exit 0
fi

[[ -x "$BIN" ]] || {
    echo "FATAL: $BIN missing. Build it first:" >&2
    echo "  bash scripts/build-agent.sh" >&2
    exit 2
}

mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <!-- The binary INSIDE the bundle, not \`open -a\`: launchd needs a process
         that stays alive, and \`open\` exits immediately. Running the bundled
         executable directly still resolves the bundle identity that
         UNUserNotificationCenter requires — verified by tests/test-agent.sh,
         which launches it exactly this way. -->
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <!-- Restart on a crash, but NOT on a clean exit. A second agent exits 0 on
         purpose when one is already running (see Singleton.swift); with
         KeepAlive=true launchd would restart it immediately and spin. -->
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
PLIST_EOF

# Obtain the notification grant BEFORE handing the agent to launchd.
#
# An agent launchd starts by exec'ing the binary directly does not get served by
# the notification system — every authorization request comes back
# "Notifications are not allowed for this application", and because a refusal is
# permanent per bundle identifier, that one attempt burns the identifier for
# good. Launching through `open` (i.e. through LaunchServices) does prompt
# normally. So: prompt once here, wait for the answer, and only then install the
# LaunchAgent, which from then on merely restarts an already-authorized app.
READY="$HOME/.claude/notifications/ghostty-agent/ready"

# One prompt round trip: launch through LaunchServices, wait for the agent to
# publish an answer, read it, then stop that instance. Stopping matters twice
# over — leaving it running would make it the incumbent, and the singleton
# guard would then send launchd's instance away, leaving launchd with nothing
# to restart if the agent ever crashes. Read BEFORE stopping: an orderly
# shutdown removes the readiness marker (it must not outlive the process it
# describes), so reading afterwards reports "no answer" for a grant that in
# fact succeeded.
prompt_once() {
    rm -f "$READY"
    open -a "$APP"
    for _ in $(seq 1 120); do
        [[ -s "$READY" ]] && break
        sleep 1
    done
    ANSWER=$(cat "$READY" 2>/dev/null || true)
    pkill -f "$BIN" 2>/dev/null || true
    sleep 1
}

if [[ "$(cat "$READY" 2>/dev/null)" != "authorized" ]]; then
    echo "==> Requesting notification permission (a dialog will appear)"
    echo "    Click Allow. Clicking Don't Allow permanently disables this build's"
    echo "    identifier — macOS leaves no System Settings entry to undo it."
    prompt_once

    # "error" is not the user's answer: the system refused to process the
    # request and no dialog ever appeared — seen on a bundle's first contact
    # with the notification system, before its registration settles. One
    # retry usually lands the dialog; reporting it as DENIED told users their
    # identifier was permanently burned when it was nothing of the sort.
    if [[ "$ANSWER" == "error" ]]; then
        echo "    macOS did not process the request (no dialog appeared); retrying once"
        sleep 2
        prompt_once
    fi

    case "$ANSWER" in
        authorized) echo "    granted" ;;
        denied)
            echo "    DENIED — the user declined, so the agent cannot display" >&2
            echo "    notifications. Hooks will keep using the alerter/terminal-notifier path." >&2
            ;;
        error)
            echo "    macOS refused the request twice (no dialog was shown)." >&2
            echo "    This is a registration hiccup, not a denial — rerun this script." >&2
            ;;
        *) echo "    no answer yet; the agent will keep running and can be re-asked" >&2 ;;
    esac
fi

unload
launchctl bootstrap "$DOMAIN" "$PLIST"

echo "==> Installed $LABEL"
echo "    plist: $PLIST"
echo "    stop:  bash scripts/install-agent.sh --uninstall"
echo
# The one setting the product needs and no code can set. macOS ignores
# NSUserNotificationAlertStyle for UNUserNotificationCenter apps — verified with a
# fresh bundle identifier carrying the key from first registration — and Apple has
# said the style is not programmatically settable. So: detect it and walk the user
# there, which is what other apps in this position do.
STYLE_FILE="$HOME/.claude/notifications/ghostty-agent/alert-style"
for _ in $(seq 1 15); do
    [[ -s "$STYLE_FILE" ]] && break
    sleep 1
done
if [[ "$(cat "$STYLE_FILE" 2>/dev/null)" == "banner" ]]; then
    echo
    echo "==> Notifications are set to Temporary, so they slide away in about five"
    echo "    seconds — and clicking one is how you jump back to the session's tab."
    echo "    Set Alert Style to Persistent in the window that just opened."
    "$BIN" --send '{"type":"style_hint"}' 2>/dev/null || true
fi

echo
echo "On first notification macOS will ask twice:"
echo "  1. permission to send notifications"
echo "  2. permission to control Ghostty (needed for click-to-jump)"
echo "Both are one-time and both must be allowed."
