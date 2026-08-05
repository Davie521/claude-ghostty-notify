import AppKit
import Foundation
import WatcherCore

/// The side-effecting half of the watcher: timers, subprocesses, signals and
/// the frontmost-application query. Every decision lives in WatcherCore; this
/// type only turns effects into syscalls.
///
/// Confined to the main actor, which is also the queue the repeating timer and
/// the AppleScript completion hop back to — that is what keeps the state
/// machine single-threaded.
@MainActor
final class Watcher {
    private let config: WatcherConfig
    private let machine: WatcherStateMachine
    private let frontFile: String?
    private let selfPid = ProcessInfo.processInfo.processIdentifier

    private var timer: DispatchSourceTimer?
    private var tabQueryRunning = false

    init(config: WatcherConfig, startedAt: Double) {
        self.config = config
        self.frontFile = ProcessInfo.processInfo
            .environment["GHOSTTY_NOTIFY_WATCHER_FRONT_FILE"]

        // Snapshot, not a per-tick read: ghostty-tab-save.sh can create the
        // unscriptable-Ghostty sentinel while we run, and re-reading it would
        // silently switch modes mid-flight (clear.sh:184-190).
        let saveData = FileManager.default.contents(atPath: config.saveFile)
        let sentinel = FileManager.default.fileExists(atPath: config.sentinelFile)

        self.machine = WatcherStateMachine(
            mode: WatcherStateMachine.resolveMode(
                saveFileJSON: saveData, sentinelExists: sentinel
            ),
            deadline: config.deadline(startedAt: startedAt),
            armDeadline: config.armDeadline(startedAt: startedAt),
            expectAlerter: config.expectAlerter
        )
    }

    // MARK: - Lifecycle

    /// clear.sh:165-182. Claim the slot BEFORE killing the predecessor, and
    /// never delete the file on the way out: an exiting watcher that cleaned
    /// up after itself could delete the successor's freshly written PID and
    /// leave it running untracked. A lingering dead PID is harmless — the kill
    /// guard ignores it and the next watcher overwrites it.
    func claimWatchPidfile() {
        let fm = FileManager.default
        try? fm.createDirectory(
            atPath: config.saveDir, withIntermediateDirectories: true
        )
        let previous = try? String(contentsOfFile: config.watchPidFile, encoding: .utf8)
        try? "\(selfPid)\n".write(
            toFile: config.watchPidFile, atomically: true, encoding: .utf8
        )
        if let victim = WatcherPidfile.takeoverKillTarget(
            pidfileContent: previous,
            selfPid: selfPid,
            sessionID: config.sessionID,
            commandLine: Self.commandLine
        ) {
            kill(victim, SIGTERM)
        }
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // Fire straight away: bash evaluates its loop body before the first
        // sleep, so the "already staring at the tab" case clears immediately.
        timer.schedule(deadline: .now(), repeating: config.poll, leeway: .milliseconds(50))
        timer.setEventHandler { MainActor.assumeIsolated { self.tick() } }
        self.timer = timer
        timer.resume()
    }

    private func tick() {
        machine.noteFrontmost(currentFront())
        let effect = machine.tick(
            TickInput(now: Date().timeIntervalSince1970, alerter: alerterState())
        )
        switch effect {
        case .none:
            break
        case .queryTab(let tabID):
            startTabQuery(tabID)
        case .clearAndExit:
            clearNotification()
            exit(0)
        case .exitSilently:
            exit(0)
        }
    }

    // MARK: - Inputs

    /// Three-valued like ghostty_front_state (clear.sh:192-206): a query that
    /// could not tell must never read as "the user left Ghostty".
    ///
    /// Sampled per tick rather than driven by NSWorkspace activation events.
    /// Both are in-process — the point of the rewrite is that waiting for a
    /// notification spawns no subprocesses at all, and this reads the same
    /// LaunchServices state `lsappinfo front` shells out for. Sampling also
    /// keeps the fallback rising edge defined exactly as the polled bash
    /// version defines it, and needs no assumption about notification delivery
    /// to a process with no GUI.
    private func currentFront() -> FrontState {
        if let frontFile {
            // Test hook standing in for the frontmost query, mirroring the
            // lsappinfo stub: absent or empty means "could not tell".
            guard let raw = try? String(contentsOfFile: frontFile, encoding: .utf8)
            else { return .unknown }
            let bundle = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundle.isEmpty else { return .unknown }
            return bundle.contains(WatcherConstants.ghosttyBundleID) ? .ghostty : .other
        }
        guard let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              !bundle.isEmpty
        else { return .unknown }
        return bundle == WatcherConstants.ghosttyBundleID ? .ghostty : .other
    }

    /// clear.sh:244-252 — file present with a numeric PID, then `kill -0`.
    private func alerterState() -> AlerterState {
        guard let raw = try? String(contentsOfFile: config.alerterPidFile, encoding: .utf8)
        else { return .missing }
        guard let pid = WatcherPidfile.parsePid(raw) else { return .unreadable }
        return kill(pid, 0) == 0 ? .alive(pid) : .dead(pid)
    }

    // MARK: - Effects

    private func startTabQuery(_ tabID: String) {
        guard !tabQueryRunning else { return }
        tabQueryRunning = true
        DispatchQueue.global(qos: .utility).async {
            let selected = Self.runTabQuery(tabID: tabID)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.tabQueryRunning = false
                    self.machine.noteTabQueryResult(selected)
                    // Run the loop body again right away so an answer never
                    // waits out a whole poll interval. Ordering (alerter
                    // lifecycle before clearing) is the tick's job, so this is
                    // just an extra tick, not a shortcut around it.
                    self.tick()
                }
            }
        }
    }

    private func clearNotification() {
        removeDelivered()
        killBlockingAlerter()
    }

    /// clear.sh:113-130. Which binary posted the notification depends on the
    /// backend that fired and removal only reaches notifications posted under
    /// the same sender bundle, so try both; removing an absent group is a
    /// silent no-op.
    private func removeDelivered() {
        if let alerter = config.alerterPath,
           FileManager.default.isExecutableFile(atPath: alerter) {
            let help = Self.run(alerter, ["--help"], mergeStderr: true) ?? ""
            let dialect = AlerterDialect.detect(helpText: help)
            _ = Self.run(alerter, [dialect.removeFlag, config.groupID])
        }
        // PATH-only, exactly like `command -v terminal-notifier` (clear.sh:127).
        // Deliberately NOT given the fixed-location probe alerter gets.
        if let tn = Self.which("terminal-notifier") {
            _ = Self.run(tn, ["-remove", config.groupID])
        }
    }

    /// clear.sh:132-137 — drop the pidfile first, then kill, and only if the
    /// process still carries both this session's marks.
    private func killBlockingAlerter() {
        let raw = try? String(contentsOfFile: config.alerterPidFile, encoding: .utf8)
        try? FileManager.default.removeItem(atPath: config.alerterPidFile)
        if let victim = WatcherPidfile.killTarget(
            pidText: raw,
            patterns: [WatcherConstants.alerterCommandPattern, config.groupID],
            commandLine: Self.commandLine
        ) {
            kill(victim, SIGTERM)
        }
    }

    // MARK: - Subprocess helpers

    private nonisolated static func runTabQuery(tabID: String) -> Bool {
        // Frontmost is re-checked inside Ghostty's own scripting suite (no
        // System Events, no accessibility). The tab id travels via env +
        // `system attribute`, never source interpolation — same injection
        // guard as ghostty-tab-focus.sh.
        let script = """
        set targetId to (system attribute "TARGET_TAB_ID")
        tell application "Ghostty"
            if not frontmost then return "no"
            try
                if (id of selected tab of front window as text) is targetId then return "yes"
            end try
            return "no"
        end tell
        """
        var env = ProcessInfo.processInfo.environment
        env["TARGET_TAB_ID"] = tabID
        // Via /usr/bin/env so osascript is resolved through PATH, which is what
        // lets the test stub stand in for it.
        let out = run("/usr/bin/env", ["osascript", "-e", script], env: env)
        return out?.trimmingCharacters(in: .whitespacesAndNewlines) == "yes"
    }

    private nonisolated static func commandLine(_ pid: Int32) -> String? {
        run("/bin/ps", ["-o", "command=", "-p", String(pid)])
    }

    private nonisolated static func which(_ name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in path.split(separator: ":") where !dir.isEmpty {
            let candidate = String(dir) + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private nonisolated static func run(
        _ path: String,
        _ args: [String],
        env: [String: String]? = nil,
        mergeStderr: Bool = false
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        if let env { process.environment = env }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = mergeStderr ? output : FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Drain before waiting: a full pipe would otherwise deadlock the child.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
