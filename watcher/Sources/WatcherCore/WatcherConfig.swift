import Foundation

/// Literals shared with the bash implementation. Each one is a contract with a
/// specific line of shell that must not drift.
public enum WatcherConstants {
    /// GROUP_ID in ghostty-notify-clear.sh:55-56 and ghostty-notify.sh:207.
    /// The two must agree or removal silently targets a group nobody posted.
    public static let groupIDPrefix = "ghostty-notify-"

    /// ghostty-notify-clear.sh:203.
    public static let ghosttyBundleID = "com.mitchellh.ghostty"

    /// One of the two substrings bash's kill_if_matches greps `ps -o command=`
    /// for when it supersedes or stops a watcher (ghostty-notify-clear.sh:160,
    /// :182); the other is the session id. Our binary is named
    /// ghostty-notify-clear-watcher and takes the session id as argv[1]
    /// precisely so the existing shell keeps matching it without changes.
    public static let watcherCommandPattern = "ghostty-notify-clear"

    /// The blocking alerter's own match pattern, paired with the group id
    /// (ghostty-notify-clear.sh:136).
    public static let alerterCommandPattern = "alerter"

    /// ghostty-notify-clear.sh:229 — DEADLINE = now + NOTIFY_TIMEOUT + 30.
    public static let deadlineGrace: Double = 30

    /// ghostty-notify-clear.sh:232 — how long to wait for the alerter subshell
    /// to register its PID before clearing anyway.
    public static let armGrace: Double = 15

    public static let defaultNotifyTimeout = 1200
    public static let defaultPoll: Double = 1

    static let saveDirSuffix = "/.claude/notifications/ghostty-sessions"
    static let sentinelName = "applescript-unavailable"
    static let alerterName = "alerter"
    static let alerterFixedDirs = ["/opt/homebrew/bin", "/usr/local/bin"]
}

/// alerter 26.2+ (the Swift rewrite) takes GNU-style `--flags`; everything
/// earlier is single-dash and prints usage instead of acting.
public enum AlerterDialect: Sendable, Equatable {
    case gnu
    case legacy

    /// Mirrors `"$ALERTER" --help 2>&1 | grep -q -- '--remove'`
    /// (ghostty-notify-clear.sh:94). Note this probes for `--remove`
    /// specifically, not the `--close-label` token ghostty-notify.sh:218 uses:
    /// removal is the only flag this binary ever sends.
    public static func detect(helpText: String) -> AlerterDialect {
        helpText.contains("--remove") ? .gnu : .legacy
    }

    public var removeFlag: String {
        switch self {
        case .gnu: return "--remove"
        case .legacy: return "-remove"
        }
    }
}

public enum WatcherConfigError: Error, Equatable {
    case invalidSessionID
    case missingHome
}

public struct WatcherConfig: Sendable, Equatable {
    public let sessionID: String
    public let home: String
    public let notifyTimeout: Int
    public let poll: Double
    public let expectAlerter: Bool
    public let alerterPath: String?

    public var saveDir: String { home + WatcherConstants.saveDirSuffix }
    public var saveFile: String { saveDir + "/" + sessionID + ".json" }
    public var alerterPidFile: String { saveDir + "/" + sessionID + ".alerter-pid" }
    public var watchPidFile: String { saveDir + "/" + sessionID + ".watch-pid" }
    public var sentinelFile: String { saveDir + "/" + WatcherConstants.sentinelName }
    public var groupID: String { WatcherConstants.groupIDPrefix + sessionID }

    public func deadline(startedAt: Double) -> Double {
        startedAt + Double(notifyTimeout) + WatcherConstants.deadlineGrace
    }

    public func armDeadline(startedAt: Double) -> Double {
        startedAt + WatcherConstants.armGrace
    }

    /// `env` is the process environment as-read, so HOME comes from getenv and
    /// follows an overridden `$HOME` — unlike FileManager's home directory,
    /// which reads passwd and would write into the real ~/.claude during
    /// sandboxed tests.
    public static func make(
        sessionID: String,
        env: [String: String],
        isExecutable: (String) -> Bool
    ) throws -> WatcherConfig {
        guard isValidSessionID(sessionID) else { throw WatcherConfigError.invalidSessionID }
        guard let home = env["HOME"], !home.isEmpty else { throw WatcherConfigError.missingHome }

        return WatcherConfig(
            sessionID: sessionID,
            home: home,
            notifyTimeout: parseTimeout(env["GHOSTTY_NOTIFY_TIMEOUT"]),
            poll: parsePoll(env["GHOSTTY_NOTIFY_FOCUS_POLL"]),
            expectAlerter: env["GHOSTTY_NOTIFY_EXPECT_ALERTER"] == "1",
            alerterPath: findAlerter(env: env, isExecutable: isExecutable)
        )
    }

    /// ghostty-notify-clear.sh:48 — the id becomes part of filesystem paths, so
    /// anything outside Claude Code's UUID alphabet is out.
    public static func isValidSessionID(_ sessionID: String) -> Bool {
        guard !sessionID.isEmpty else { return false }
        return sessionID.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    /// ghostty-notify-clear.sh:64-72. Non-integer / unparseable values fail
    /// closed to the default, the same way `[[ =~ ]] || VAR=default` does.
    static func parseTimeout(_ raw: String?) -> Int {
        guard let raw, !raw.isEmpty, raw.allSatisfy(\.isASCIIDigit), let value = Int(raw) else {
            return WatcherConstants.defaultNotifyTimeout
        }
        return value
    }

    /// POLL accepts decimals: `^[0-9]+([.][0-9]+)?$`.
    static func parsePoll(_ raw: String?) -> Double {
        guard let raw, !raw.isEmpty else { return WatcherConstants.defaultPoll }
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        let wellFormed: Bool
        switch parts.count {
        case 1: wellFormed = !parts[0].isEmpty && parts[0].allSatisfy(\.isASCIIDigit)
        case 2:
            wellFormed = !parts[0].isEmpty && parts[0].allSatisfy(\.isASCIIDigit)
                && !parts[1].isEmpty && parts[1].allSatisfy(\.isASCIIDigit)
        default: wellFormed = false
        }
        guard wellFormed, let value = Double(raw) else { return WatcherConstants.defaultPoll }
        // clear.sh:62-65 — zero is syntactically valid but turns the loop into
        // a CPU-pegging spin, so it fails closed like every other numeric knob.
        guard value > 0 else { return WatcherConstants.defaultPoll }
        return value
    }

    /// ghostty-notify-clear.sh:64-72. `${GHOSTTY_NOTIFY_ALERTER:-...}` is `:-`,
    /// not `-`: an empty override falls back to discovery. (The WATCHER_BIN
    /// hand-off in the shell deliberately uses `-` instead, so that an empty
    /// value there means "stay on bash".)
    public static func findAlerter(
        env: [String: String],
        isExecutable: (String) -> Bool
    ) -> String? {
        if let override = env["GHOSTTY_NOTIFY_ALERTER"], !override.isEmpty { return override }

        // `command -v alerter`
        for dir in (env["PATH"] ?? "").split(separator: ":") where !dir.isEmpty {
            let candidate = String(dir) + "/" + WatcherConstants.alerterName
            if isExecutable(candidate) { return candidate }
        }

        // Hooks can run with a trimmed PATH, so probe the usual install sites.
        var fixed = WatcherConstants.alerterFixedDirs
        fixed.append((env["HOME"] ?? "") + "/.local/bin")
        for dir in fixed {
            let candidate = dir + "/" + WatcherConstants.alerterName
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }
}

/// Pidfile arithmetic, kept pure so the PID-reuse guard is unit-testable.
public enum WatcherPidfile {
    /// `$(cat file)` drops trailing newlines and nothing else — a pidfile with
    /// leading whitespace fails bash's `^[0-9]+$` test, so it must fail here.
    static func fileText(_ raw: String?) -> String {
        var text = raw ?? ""
        while text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    /// ghostty-notify-clear.sh:98, :246 — `^[0-9]+$`.
    public static func parsePid(_ text: String?) -> Int32? {
        let trimmed = fileText(text)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isASCIIDigit) else { return nil }
        return Int32(trimmed)
    }

    /// ghostty-notify-clear.sh:91-111 — only ever kill a process whose command
    /// line still carries THIS session's marks, ALL of them. A stale pidfile
    /// plus PID reuse would otherwise take down another session's alerter (any
    /// alerter matches "alerter") or watcher.
    public static func killTarget(
        pidText: String?,
        patterns: [String],
        commandLine: (Int32) -> String?
    ) -> Int32? {
        guard let pid = parsePid(pidText) else { return nil }
        // `[[ -n "$cmd" ]] || return 0` — an empty ps line means it is gone.
        guard let command = commandLine(pid), !command.isEmpty else { return nil }
        guard patterns.allSatisfy({ command.contains($0) }) else { return nil }
        return pid
    }

    /// ghostty-notify-clear.sh:179-182 — supersede the previous watcher for
    /// this session, but never ourselves.
    public static func takeoverKillTarget(
        pidfileContent: String?,
        selfPid: Int32,
        sessionID: String,
        commandLine: (Int32) -> String?
    ) -> Int32? {
        let text = fileText(pidfileContent)
        guard text != String(selfPid) else { return nil }
        return killTarget(
            pidText: text,
            patterns: [WatcherConstants.watcherCommandPattern, sessionID],
            commandLine: commandLine
        )
    }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
