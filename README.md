# claude-ghostty-notify

[![CI](https://github.com/Davie521/claude-ghostty-notify/actions/workflows/ci.yml/badge.svg)](https://github.com/Davie521/claude-ghostty-notify/actions/workflows/ci.yml)

> **The moment a long Claude Code task finishes, get pulled back to the _exact_ Ghostty tab that ran it — not the app, not the frontmost tab, _that_ tab.**

**[中文版 / 中文说明点这里](./README.zh-CN.md)**

---

## The problem it solves

You kick off a long Claude Code run — a sprawling refactor, a full test suite, a database migration — and switch to your browser while it works. Ten minutes later you tab back to Ghostty and… you have eight tabs open, three of them running Claude, and no idea which one just finished. You squint at each buffer, scroll to check, lose your place. Now multiply that by a dozen times a day.

`claude-ghostty-notify` closes that loop. When the task completes, macOS shows a notification. Click **Go to tab** and Ghostty jumps straight to the surface that ran it — even if five other Claude sessions are open in the same project folder. You never hunt for a tab again.

It's a handful of small, dependency-light bash scripts you can read end to end. No daemon, no Node process, no telemetry, no accessibility permissions.

## What makes it different

Plenty of tools ping you when Claude finishes. This one is built around the parts everything else gets wrong.

### Land on the right tab — every time

Most notifiers can only bring Ghostty to the foreground; you're still left to find the tab yourself. This one identifies the **exact surface**. On the first tool call of a session it writes a unique marker into the tab's title via an OSC 2 escape sequence, asks Ghostty over AppleScript which tab now carries that marker, records the answer, and restores the original title — all in a fraction of a second, and only once per session.

Two Claude sessions in the *same* directory share a `cwd`, so directory-matching notifiers can't tell them apart. Each session here gets its own marker, so the jump is never ambiguous.

### Three tiers, so short tasks never spam you

| Elapsed task time | What happens |
|---|---|
| `< 3 min` | **Silent** — no notification at all |
| `3 – 10 min` | **Notification, no sound** — glance at Notification Center if you wandered off |
| `≥ 10 min` | **Notification with Glass chime** — you've clearly walked away, we'll wake you |

A two-second `ls` stays silent. A three-minute build gets a quiet, glanceable notification. A ten-minute migration wakes you with a chime. Every threshold is an environment variable — tune them to your own rhythm.

Notifications fire on task completion (`Stop`). Permission and input prompts (`Notification` events) are silent by default — under bypass-permissions mode they're rare, and the terminal bell already covers them. Run the default permission mode instead? Flip on `GHOSTTY_NOTIFY_ON_PROMPT=1` and you'll get an immediate ping whenever Claude blocks on a prompt in a background tab, so a stalled task never masquerades as a running one.

### Clicks that actually work

Modern macOS silently drops action-button clicks on banner-style notifications — the reason so many notifier tools feel subtly broken. This plugin prefers `alerter`, whose alert-style notifications carry a real **Go to tab** button that fires reliably, and degrades to `terminal-notifier` when alerter isn't available.

### No accessibility permission, ever

Tab switching uses Ghostty's native AppleScript `select tab` command — an actual scripting verb in Ghostty's dictionary, not simulated keystrokes. You never grant Accessibility access, and a macOS update can't quietly break it.

### Multi-session aware, resume-proof

State is keyed by Claude's `session_id`, never a PID or a working directory. Run as many concurrent sessions as you like; each one remembers its own tab, and the mapping survives `--resume` because the session id is stable across the whole conversation.

### Hardened for the messy real world

The convenient stuff is easy; the edge cases are where notifier tools rot. This one is built to stay quiet instead of adding new surprises:

- **Interrupted a round with Esc, or a session crashed?** The round timer re-arms on your next prompt, so you never get a loud "finished after 20m" alert for a 10-second follow-up.
- **Ghostty too old to script, Automation permission denied, or running inside tmux?** It detects that once, backs off, and degrades to simply activating Ghostty — no tab title left stuck showing a marker string, no per-tool-call latency tax.
- **Parallel tool calls racing on the same tab?** The marker round-trip is serialized, so concurrent hooks can't rename your tab out from under you.
- **Malformed config or a crafted state file?** Non-integer thresholds fail closed to the defaults, and tab ids reach AppleScript as data (never interpolated into the script source), so nothing you didn't type can run.

Every one of these paths has an automated regression test, and CI runs the full suite on macOS on every change.

## How it compares

| | `claude-ghostty-notify` | Typical Claude notifier |
|---|---|---|
| Jumps to the **exact** tab | Yes | Brings the app forward; you find the tab |
| Suppresses short-task noise | 3-tier elapsed gate | Every `ls` pings you |
| Two sessions in one folder | Disambiguated by marker | Confused by shared `cwd` |
| Accessibility permission | Not needed | Sometimes required (keystroke sim) |
| Survives Claude Code / plugin updates | Pure bash you own | Often breaks on upgrade |

Prior art worth a look — [code-notify](https://github.com/mylee04/code-notify), [claude-code-notifier](https://github.com/kovoor/claude-code-notifier), [claude-notifications-go](https://github.com/777genius/claude-notifications-go) — each solves part of the problem; the table above is where this one goes further.

## Installation

### 1. Install dependencies

```bash
brew install jq alerter
```

- **jq** — parses the JSON Claude Code passes to hooks
- **alerter** — shows persistent macOS notifications with action buttons (clicks aren't reliable on stock `terminal-notifier` banners)

### 2. Install the plugin

Inside Claude Code, run:

```
/plugin marketplace add Davie521/claude-ghostty-notify
/plugin install claude-ghostty-notify
```

That's it — hooks are auto-registered via the plugin manifest. **No manual `settings.json` edits needed.**

### 3. Flip one macOS setting

**System Settings → Notifications → Alert Style → Persistent**, for **both** the **Script Editor** and **Terminal** entries (whichever ones exist on your machine).

> Which bundle delivers the notification depends on your alerter version: legacy alerter (≤1.x, the ObjC builds) borrows the Script Editor bundle, while alerter 26.x (the Swift rewrite) defaults to `com.apple.Terminal` — its `--help` documents `--sender ... (default: com.apple.Terminal)`. Setting both is harmless and covers either version. **Persistent** style keeps the notification on screen until you dismiss it, and shows the **Go to tab** button directly. Banner style auto-hides and tucks the button behind a "Show" chevron — clicks won't reliably trigger.

### 4. Restart Claude Code

Quit and relaunch so the new hooks are loaded.

You're done. Default thresholds (3 min / 10 min / 20 min timeout) work out of the box — see [Configuration](#configuration) to tune them.

---

### Manual install (without the plugin system)

If you'd rather not use the plugin marketplace, the legacy installer still works:

```bash
git clone https://github.com/Davie521/claude-ghostty-notify.git
cd claude-ghostty-notify
./install.sh
```

It copies the hooks to `~/.claude/hooks/` and prints a `settings.json` snippet to merge manually. See [example-settings.json](./example-settings.json) for the exact JSON.

## Configuration

All thresholds are controlled by environment variables in your `settings.json` `env` block. Restart Claude Code for changes to take effect. Defaults are tuned for a workflow where most tasks finish under 3 minutes — only longer tasks get notifications.

| Variable | Default | What it means |
|---|---:|---|
| `GHOSTTY_NOTIFY_MIN_ELAPSED`   | `180`  | Below this elapsed time (3 min): **silent** — no notification at all |
| `GHOSTTY_NOTIFY_SOUND_ELAPSED` | `600`  | Below this (10 min) but above MIN: notification **without** sound |
| `GHOSTTY_NOTIFY_TIMEOUT`       | `1200` | How long the notification stays on screen before auto-dismissing (20 min) |
| `GHOSTTY_NOTIFY_BACKEND`       | `auto` | `auto` (alerter then terminal-notifier) or `terminal-notifier` (force). Set to `terminal-notifier` if alerter notifications never appear — see Troubleshooting. Note the terminal-notifier backend never wires click-to-jump (its `-execute` fires on dismiss too), and a forced-but-missing alerter degrades to terminal-notifier instead of silently dropping the notification. |
| `GHOSTTY_NOTIFY_ON_PROMPT`     | `0`    | Set to `1` to also alert (immediately, with Ping sound) on `Notification` events — permission / input prompts. Recommended if you do NOT run bypass-permissions mode. |

Values must be plain integers (seconds); anything else falls back to the default.

Example — notify on tasks over 30 seconds, sound past 5 minutes, persist 20 minutes:

```json
"env": {
  "GHOSTTY_NOTIFY_MIN_ELAPSED": "30",
  "GHOSTTY_NOTIFY_SOUND_ELAPSED": "300",
  "GHOSTTY_NOTIFY_TIMEOUT": "1200"
}
```

## Troubleshooting

### I don't see any notifications

1. Did you change Script Editor **and Terminal** to **Persistent** alert style? (Step 3 — which bundle delivers depends on your alerter version.)
2. Did you restart Claude Code after adding the env vars? (Step 4.)
3. Is macOS **Do Not Disturb / Focus** mode on? Turn it off and test again.
4. Check the hooks ran: `ls ~/.claude/notifications/ghostty-sessions/` — you should see a `<session_id>.json` and `.start` file for the current session.
5. **alerter notifications never appear (even though the script ran)** — this happens when the delivering bundle was never authorized for notifications in System Settings. `alerter` will run, exit cleanly, and macOS silently drops the visual. Fix by forcing the terminal-notifier backend (its bundle has its own notification authorization):

   ```json
   "env": {
     "GHOSTTY_NOTIFY_BACKEND": "terminal-notifier"
   }
   ```

### I see two notifications (one with Script Editor icon showing my assistant message text)

That's the `stop:desktop-notify` hook from [everything-claude-code](https://github.com/affaan-m/everything-claude-code) (ECC) — a popular plugin that ships its own notifier. It fights with this project. Disable just that one ECC hook (the rest of ECC keeps working):

```json
"env": {
  "ECC_DISABLED_HOOKS": "stop:desktop-notify"
}
```

### Click goes to Script Editor's "New Document" dialog, not Ghostty

That means clicking the notification body (not the **Go to tab** button). `alerter` routes body clicks to its `--sender` app, and Script Editor's default on activation is the New Document dialog. Either:

- Always click the **Go to tab** button (preferred), or
- Enable Ghostty notification permissions and we can add `--sender com.mitchellh.ghostty` to the script — but Ghostty will then start sending its own `notify-on-command-finish-after` notifications, which may be noisy.

### It jumps to the wrong tab

Two likely causes:

1. You resumed the Claude session (`--resume`) in a new tab. The saved tab id from the original run is stale. Fix: `rm ~/.claude/notifications/ghostty-sessions/<session_id>.json` and run any tool call to re-capture the current tab.
2. The tab that was running Claude was closed. Falls back to just activating Ghostty.

### The alerter process is hanging around after the notification

Normal. `alerter` blocks until you click an action or the notification times out (`GHOSTTY_NOTIFY_TIMEOUT` seconds). If you want a leftover one gone: `pkill -f 'alerter.*ghostty-notify'`.

## How it works (technical)

**Hook 1 — `ghostty-tab-save.sh` (runs on every `PreToolUse`):**

1. Reads the JSON Claude Code pipes to stdin; extracts `session_id` and `cwd`.
2. Records a start timestamp (first tool call of the round).
3. Walks the process tree upward (`ps -o ppid= / command=`) until it finds the `claude` process — that's the one whose controlling TTY hosts the user-visible terminal.
4. Verifies Ghostty is AppleScript-scriptable, then writes an OSC 2 escape sequence to that TTY with a marker string containing the session ID. This briefly changes the tab title to the marker.
5. Queries Ghostty via AppleScript to find which tab's title equals the marker — that's us.
6. Restores the original title (via a `trap EXIT` so it runs even if anything above fails).
7. Saves `{tab_id, cwd}` to `~/.claude/notifications/ghostty-sessions/<session_id>.json`.

The expensive marker dance runs once per session, serialized under a lock so parallel tool calls can't race. If Ghostty can't be scripted (or the marker can't round-trip, e.g. inside tmux), it backs off and the session degrades to activate-only.

**Hook 2 — `ghostty-notify.sh` (runs on `Stop`, and on `Notification` when opted in):**

1. Reads the start timestamp from `PreToolUse`.
2. Computes elapsed seconds; exits silently if below `MIN_ELAPSED`.
3. Fires `alerter` in a backgrounded subshell with an explicit `Go to tab` action button. Omits the sound if elapsed is below `SOUND_ELAPSED`.
4. The subshell captures `alerter`'s stdout and invokes the focus script only for the `Go to tab` button or a body click (`@CONTENTCLICKED`) — dismiss and timeout do nothing.
5. Clears the start file on Stop so the next round re-arms.

**Hook 2b — `ghostty-round-reset.sh` (runs on `UserPromptSubmit`):**

Clears the round-start timestamp. The Stop hook can't do this when a round ends via interrupt (Esc/Ctrl-C) or a crash — without this reset, the stale timestamp would inflate the next round's elapsed time and fire a loud false "Finished after 20m" notification for a 10-second task.

**Hook 3 — `ghostty-tab-focus.sh` (runs when you click Go to tab):**

1. Activates Ghostty (`tell application "Ghostty" to activate`).
2. Reads `tab_id` from the session save file.
3. Uses Ghostty's native AppleScript command `select tab` to switch to it. This is a real command in the sdef, not a property write, so no accessibility permission is needed.

### Design notes

- **Why `session_id` and not `$PPID`?** Claude Code spawns intermediate shells with non-deterministic PIDs between hook invocations. `session_id` (from hook stdin JSON) is stable across the whole conversation, including `--resume`.
- **Why an OSC 2 marker and not `cwd` matching?** Two Claude sessions in the same project folder share the same `cwd`. The marker gives us a unique per-session signal that nails the exact tab regardless.
- **Why `alerter` and not `terminal-notifier`?** On modern macOS, Banner-style notifications silently drop `-execute` clicks. `alerter` is alert-style by design and uses explicit action buttons, which work reliably.

## Uninstall

**Plugin install:**

```
/plugin uninstall claude-ghostty-notify
```

That's it — hooks are automatically deregistered.

**Manual install:**

```bash
rm -f ~/.claude/hooks/ghostty-tab-save.sh \
      ~/.claude/hooks/ghostty-tab-focus.sh \
      ~/.claude/hooks/ghostty-notify.sh \
      ~/.claude/hooks/ghostty-round-reset.sh
rm -rf ~/.claude/notifications/ghostty-sessions
rm -f ~/.claude/notifications/state/ghostty-notify-*
```

Then remove the `env` and `hooks` entries from `~/.claude/settings.json`.

## Limitations

- **macOS only.** Depends on Ghostty's AppleScript dictionary and macOS notification APIs.
- **Ghostty only.** The tab-identification trick is Ghostty-specific.
- **Session must have started in Ghostty.** If Claude's controlling TTY isn't a Ghostty surface, the hooks exit silently.
- **Tab closed after save.** If you close the tab hosting Claude, clicking the notification falls back to just activating Ghostty.
- **Ghostty must be scriptable.** Tab identification needs Ghostty ≥ 1.3 (AppleScript support) and the macOS Automation permission. If either is missing, the hooks detect it once, back off for a day, and notifications degrade to activate-only. Same for `claude` running inside tmux (OSC 2 retitles the tmux pane, not the Ghostty tab): after 3 failed attempts the session degrades to activate-only.

## Credits

Inspired by the existing Claude Code notification ecosystem, especially the TTY-marker idea discussed in [kovoor/claude-code-notifier](https://github.com/kovoor/claude-code-notifier).

## License

[MIT](./LICENSE).
