# claude-ghostty-notify

Tab-level click-through notifications for [Claude Code](https://github.com/anthropics/claude-code) running in [Ghostty](https://ghostty.org) on macOS.

When a long-running Claude task finishes, pop a macOS notification — click it, and Ghostty jumps to *the specific tab* that was running Claude. Works across multiple concurrent Claude sessions.

## What it does

| elapsed | behavior |
|--------:|----------|
| `< 45s`         | completely silent, no notification |
| `45s – 120s`    | silent notification (no sound) |
| `≥ 120s`        | notification with Glass/Ping sound |

On click: jumps Ghostty to the tab where *that* session was running — not just the app — even if you have several Ghostty tabs / windows / concurrent Claude sessions in the same project directory.

## Why

Existing tools ([code-notify](https://github.com/mylee04/code-notify), [kovoor/claude-code-notifier](https://github.com/kovoor/claude-code-notifier), [777genius/claude-notifications-go](https://github.com/777genius/claude-notifications-go)) either:

- don't do tab-level focus, or
- don't suppress short-task noise, or
- break on plugin updates

This project:

- **Precise tab identification** via OSC 2 marker round-trip (identifies the exact tab hosting each Claude process — not the frontmost tab, not a cwd guess)
- **Three-tier elapsed gate** so your inbox isn't spammed with `ls` notifications
- **Tab-title safe** — trap-based title restore even on early-exit errors
- **Independent of Claude Code plugins** — pure bash + system tools, survives Claude Code and plugin updates
- **No compiled binary, no URL scheme registration, no accessibility permissions**

## How it works

1. **PreToolUse hook** (`ghostty-tab-save.sh`) runs once per Claude session:
   - finds Claude's controlling TTY by walking the process tree
   - writes an OSC 2 escape to that TTY with a marker string containing the session ID
   - asks Ghostty (via AppleScript) which tab's title now equals the marker
   - saves `{tab_id, cwd}` keyed by Claude's `session_id`
   - a `trap EXIT` restores the original tab title, even on error
   - also records the task start time for the elapsed-gate
2. **Stop hook** (`ghostty-notify.sh`) fires when Claude finishes a round:
   - reads the start time to compute elapsed seconds
   - silently exits for short tasks
   - otherwise launches [alerter](https://github.com/alloy/terminal-notifier/tree/alerter) in the background with a `Go to tab` action button
3. **Click handler** (`ghostty-tab-focus.sh`) runs when user clicks the button:
   - activates Ghostty
   - resolves `tab_id` from the saved session file
   - runs `select tab` via Ghostty's native AppleScript dictionary

Key technical notes:

- Uses Claude Code's `session_id` from the hook `stdin` JSON — stable across forks, resume, and subshells. PPID-based schemes don't work (Claude spawns intermediate shells with non-deterministic PIDs).
- Ghostty's AppleScript dictionary exposes `select tab` as a command (not a property), so no accessibility permission is needed — unlike `System Events` keystroke simulation.
- The OSC 2 marker is written to Claude's TTY (not the hook's stdin, which is JSON), found via walking `ps -o ppid= / ps -o command=` for the `claude` process.

## Install

### Prerequisites

```bash
brew install jq alerter
```

- `jq` — parses hook JSON
- `alerter` — persistent-style macOS notifications with action buttons

### One-liner

```bash
curl -fsSL https://raw.githubusercontent.com/Davie521/claude-ghostty-notify/main/install.sh | bash
```

### Manual

```bash
git clone https://github.com/Davie521/claude-ghostty-notify.git
cd claude-ghostty-notify
./install.sh
```

Then merge the snippet from `example-settings.json` into your `~/.claude/settings.json`.

### macOS notification style

Required one-time system setting:

**System Settings → Notifications → Script Editor → Alert Style → Persistent**

(alerter's notifications are attributed to Script Editor by default. Persistent keeps them on-screen with visible action buttons — Banner-style notifications hide the `Go to tab` button behind a `Show` chevron.)

## Configuration

Three env vars in `~/.claude/settings.json`:

```json
{
  "env": {
    "GHOSTTY_NOTIFY_MIN_ELAPSED": "45",
    "GHOSTTY_NOTIFY_SOUND_ELAPSED": "120",
    "GHOSTTY_NOTIFY_TIMEOUT": "600"
  }
}
```

| var | default | meaning |
|---|---:|---|
| `GHOSTTY_NOTIFY_MIN_ELAPSED`   | 60  | below this, completely silent (no notification) |
| `GHOSTTY_NOTIFY_SOUND_ELAPSED` | 300 | below this but above MIN, notification without sound |
| `GHOSTTY_NOTIFY_TIMEOUT`       | 120 | how long alerter keeps the notification on-screen before auto-dismissing |

Env vars are read at Claude Code startup — **restart Claude Code for changes to take effect.**

### If you use [everything-claude-code (ECC)](https://github.com/affaan-m/everything-claude-code)

ECC ships its own `stop:desktop-notify` hook that fires a `Claude Code` notification with the assistant message on every Stop. It will fight with this project. Disable it:

```json
{
  "env": {
    "ECC_DISABLED_HOOKS": "stop:desktop-notify"
  }
}
```

## Uninstall

```bash
rm -f ~/.claude/hooks/ghostty-tab-save.sh \
      ~/.claude/hooks/ghostty-tab-focus.sh \
      ~/.claude/hooks/ghostty-notify.sh
rm -rf ~/.claude/notifications/ghostty-sessions
```

And remove the hook entries + env vars from `~/.claude/settings.json`.

## Limitations

- **macOS only.** Relies on Ghostty's AppleScript dictionary and macOS notifications.
- **Ghostty only.** The tab-resolution technique is specific to Ghostty's AppleScript API.
- **Session must start in Ghostty.** If Claude's controlling TTY isn't a Ghostty surface, the hook exits silently.
- **Tab closed after save.** If you close the tab that Claude was in, clicking the notification falls back to just activating Ghostty (no jump).

## License

MIT — see [LICENSE](LICENSE).
