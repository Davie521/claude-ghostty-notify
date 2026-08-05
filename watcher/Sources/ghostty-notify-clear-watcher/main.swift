import Foundation
import WatcherCore

// Native replacement for `ghostty-notify-clear.sh --watch <session_id>`.
//
// ghostty-notify-clear.sh execs this binary (so the PID is preserved) when it
// exists, and runs its own poll loop when it does not. The session id has to
// stay in argv: the shell's kill_if_matches identifies a watcher by grepping
// `ps -o command=` for "ghostty-notify-clear" AND the session id, and that is
// how the immediate-clear path and watcher supersession reach this process.
//
// Every early exit is silent with status 0, matching the shell it replaces —
// a watcher that cannot run must never turn into a visible hook failure.
//
// SIGTERM is left at its default disposition on purpose. The watch pidfile is
// deliberately never released on exit (see Watcher.claimWatchPidfile), so
// there is nothing to clean up, and dying promptly is exactly what
// supersession and the prompt-submit clear expect.

let startedAt = Date().timeIntervalSince1970

guard CommandLine.arguments.count > 1 else { exit(0) }
let sessionID = CommandLine.arguments[1]

guard let config = try? WatcherConfig.make(
    sessionID: sessionID,
    // getenv, not FileManager's home directory: the latter reads passwd and
    // would ignore an overridden $HOME, writing into the real ~/.claude during
    // sandboxed tests.
    env: ProcessInfo.processInfo.environment,
    isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }
) else { exit(0) }

let watcher = Watcher(config: config, startedAt: startedAt)
watcher.claimWatchPidfile()
watcher.start()

// Parks the main thread as the main queue's worker: the timer, the AppleScript
// completion and every state-machine call all run here, serially.
dispatchMain()
