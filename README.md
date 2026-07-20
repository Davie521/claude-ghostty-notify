# claude-ghostty-notify

[![CI](https://github.com/Davie521/claude-ghostty-notify/actions/workflows/ci.yml/badge.svg)](https://github.com/Davie521/claude-ghostty-notify/actions/workflows/ci.yml)

> Tab-level click-through notifications for [Claude Code](https://github.com/anthropics/claude-code) running in [Ghostty](https://ghostty.org) on macOS.

**[中文版 / 中文说明点这里](./README.zh-CN.md)**

---

When a long-running Claude task finishes, a macOS notification pops up. Click **Go to tab**, and Ghostty jumps straight to the exact tab that was running that Claude session — not the frontmost tab, not the app, **that specific tab**. Works across multiple concurrent Claude sessions in the same project.

## What you get

Three tiers of notifications, so short tasks don't spam you:

| Elapsed task time | What happens |
|---|---|
| `< 3 min` | **Silent** — no notification at all |
| `3 – 10 min` | **Notification, no sound** — glance at Notification Center if you wandered off |
| `≥ 10 min` | **Notification with Glass sound** — you've clearly walked away, we'll wake you |

Fires on task completion (`Stop`). Input / permission prompts (`Notification` events) are ignored by default — under bypass-permissions mode they're rare, and when they do fire, the terminal bell already covers them. If you run the default permission mode, set `GHOSTTY_NOTIFY_ON_PROMPT=1` to get an immediate Ping alert whenever Claude blocks on a prompt in a background tab (otherwise a stalled task looks exactly like a running one).

The thresholds are all configurable via env vars.

## Why this exists

Other Claude Code notification tools ([code-notify](https://github.com/mylee04/code-notify), [claude-code-notifier](https://github.com/kovoor/claude-code-notifier), [claude-notifications-go](https://github.com/777genius/claude-notifications-go)) either:

- don't do tab-level focus (they bring the app forward, you still have to find the right tab yourself),
- don't suppress short-task noise (every 2-second `ls` fires a notification), or
- break when you upgrade Claude Code / plugins.

This project:

- **Precise tab identification** — writes a unique marker to the terminal's title via OSC 2, queries Ghostty via AppleScript to find which tab got the marker, then restores the title. Works even if you have several Claude sessions in the same project folder.
- **Three-tier elapsed gate** — configurable silence/silent-notify/loud-notify thresholds.
- **No accessibility permission required** — uses Ghostty's native AppleScript `select tab` command, not keystroke simulation.
- **Immune to Claude Code & plugin updates** — pure bash hooks you own, with `alerter` as the preferred backend (action-button-based clicks) and `terminal-notifier` as a fallback you can force via env var.
- **Multi-session aware** — keys saved state by Claude's `session_id`, so several concurrent sessions each know their own tab.

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

All three thresholds are controlled by environment variables in your `settings.json` `env` block. Restart Claude Code for changes to take effect. Defaults are tuned for a workflow where most tasks finish under 3 minutes — only longer tasks get notifications.

| Variable | Default | What it means |
|---|---:|---|
| `GHOSTTY_NOTIFY_MIN_ELAPSED`   | `180`  | Below this elapsed time (3 min): **silent** — no notification at all |
| `GHOSTTY_NOTIFY_SOUND_ELAPSED` | `600`  | Below this (10 min) but above MIN: notification **without** sound |
| `GHOSTTY_NOTIFY_TIMEOUT`       | `1200` | How long the notification stays on screen before auto-dismissing (20 min) |
| `GHOSTTY_NOTIFY_BACKEND`       | `auto` | `auto` (alerter then terminal-notifier) or `terminal-notifier` (force). Set to `terminal-notifier` if alerter notifications never appear — see Troubleshooting. Note the terminal-notifier backend never wires click-to-jump (its `-execute` fires on dismiss too), and a forced-but-missing alerter degrades to terminal-notifier instead of silently dropping the notification. |
| `GHOSTTY_NOTIFY_ON_PROMPT`     | `0`    | Set to `1` to also alert (immediately, with Ping sound) on `Notification` events — permission / input prompts. Recommended if you do NOT run bypass-permissions mode. |

Values must be plain integers (seconds); anything else falls back to the default.

Example: notify on tasks > 30 seconds, sound on > 5 minutes, persist 20 minutes:

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
5. **alerter notifications never appear (even though the script ran)** — this happens when Script Editor's bundle was never authorized for notifications in System Settings. `alerter` will run, exit cleanly, and macOS silently drops the visual. Fix by forcing the terminal-notifier backend (its bundle has its own notification authorization):

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
4. Writes an OSC 2 escape sequence to that TTY with a marker string containing the session ID. This briefly changes the tab title to the marker.
5. Queries Ghostty via AppleScript to find which tab's title equals the marker — that's us.
6. Restores the original title (via a `trap EXIT` so it runs even if anything above fails).
7. Saves `{tab_id, cwd}` to `~/.claude/notifications/ghostty-sessions/<session_id>.json`.

Only runs the expensive marker dance once per session (the save file is kept around).

**Hook 2 — `ghostty-notify.sh` (runs on `Stop`):**

1. Reads the start timestamp from `PreToolUse`.
2. Computes elapsed seconds; exits silently if below `MIN_ELAPSED`.
3. Fires `alerter` in a backgrounded subshell with an explicit `Go to tab` action button. Omits `--sound` if elapsed is below `SOUND_ELAPSED`.
4. The subshell captures `alerter`'s stdout and fires the focus script only for the `Go to tab` button or a body click (`@CONTENTCLICKED`) — dismiss/timeout do nothing.
5. Clears the start file on Stop so the next round re-arms.

**Hook 2b — `ghostty-round-reset.sh` (runs on `UserPromptSubmit`):**

Clears the round-start timestamp. The Stop hook can't do this when a round ends via interrupt (Esc/Ctrl-C) or a crash — without this reset, the stale timestamp would inflate the next round's elapsed time and fire a loud false "Finished after 20m" notification for a 10-second task.

**Hook 3 — `ghostty-tab-focus.sh` (runs when user clicks Go to tab):**

1. Activates Ghostty (`tell application "Ghostty" to activate`).
2. Reads `tab_id` from the session save file.
3. Uses Ghostty's native AppleScript command `select tab` to switch to it. This is an actual command in the sdef, not a property write, so no accessibility permission is needed.

### Design notes

- **Why `session_id` and not `$PPID`?** Claude Code spawns intermediate shells with non-deterministic PIDs between hook invocations. `session_id` (from hook stdin JSON) is stable across the whole conversation including `--resume`.
- **Why OSC 2 marker and not `cwd` matching?** Two Claude sessions in the same project folder share the same `cwd`. Marker gives us a unique per-session signal that nails the exact tab regardless.
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
