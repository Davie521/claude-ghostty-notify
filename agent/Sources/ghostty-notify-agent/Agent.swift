import AppKit
import Foundation
import NotifyCore
import UserNotifications

/// The resident app. One process serves every Claude session on the machine:
/// it owns the notification center, subscribes to app-activation events instead
/// of polling for them, and answers clicks by driving Ghostty over Apple Events.
///
/// Nothing here decides *whether* to withdraw a notification — that lives in
/// `NotifyCore.SessionState` so the rules can be tested without a run loop.
@MainActor
final class Agent: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let paths: AgentPaths
    private let notifier: Notifier
    private var state = SessionState()
    private var spool: SpoolWatcher?
    private var pruneTimer: DispatchSourceTimer?
    private var activationObserver: NSObjectProtocol?
    /// Per-identifier expiry timers, so a replacement notification restarts the
    /// clock instead of inheriting the old one's deadline.
    private var expiryTimers: [String: DispatchSourceTimer] = [:]

    init(paths: AgentPaths) {
        self.paths = paths
        let logPath = paths.log
        self.notifier = Notifier(log: { AgentLog.append($0, to: logPath) })
        super.init()
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(
            atPath: paths.root, withIntermediateDirectories: true)
        writePidFile()
        loadState()
        log("agent up pid=\(getpid()) bundle=\(Bundle.main.bundleIdentifier ?? "<none>")")

        notifier.setDelegate(self)
        notifier.registerCategories()
        notifier.requestAuthorization { [weak self] granted in
            guard let self else { return }
            self.log("authorization granted=\(granted)")
            // Publish the answer: until this file says "authorized", the hooks
            // must not treat a spooled request as a delivered notification, or a
            // user who clicked "Don't Allow" would silently get nothing at all.
            self.publishReadiness(granted)
            if !granted {
                self.log("notifications are not authorized — see System Settings › Notifications")
            }
        }

        observeActivation()
        startPruning()

        let watcher = SpoolWatcher(
            directory: paths.spool,
            log: { [weak self] in self?.log($0) },
            onRequest: { [weak self] in self?.handle($0) }
        )
        watcher.start()
        spool = watcher
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveState()
        try? FileManager.default.removeItem(atPath: paths.pidFile)
        // Readiness is about a live agent, so it must not outlive the process:
        // a stale "authorized" would keep hooks routing into a dead spool.
        try? FileManager.default.removeItem(atPath: paths.readyFile)
        log("agent down")
    }

    // MARK: - Requests

    private func handle(_ request: AgentRequest) {
        switch request {
        case .notify(let notify):
            // A tab id supplied by the hook is authoritative: it came from the
            // marker round-trip, which is correct regardless of what is focused
            // now. Record it before deciding anything.
            state.anchor(sessionID: notify.sessionID, tabID: notify.tabID, now: Agent.now())
            deliver(notify)
            shortenIfAlreadyWatching(notify)

        case .dismiss(let sessionID):
            let identifiers = state.takeNotifications(sessionID: sessionID)
            cancelExpiry(identifiers)
            notifier.withdraw(identifiers)
            saveState()

        case .anchor(let sessionID, let tabID):
            if let tabID {
                state.anchor(sessionID: sessionID, tabID: tabID, now: Agent.now())
                log("anchored \(sessionID) -> \(tabID)")
                saveState()
            } else {
                // No id from the hook (tmux, or the marker round-trip never
                // succeeded). Sampling the focused tab is a guess — the drain
                // can run a second after the prompt was submitted — so it only
                // fills a gap, never overwrites a known id.
                let known = state.sessions[sessionID]?.tabID
                guard known == nil else {
                    state.anchor(sessionID: sessionID, tabID: known, now: Agent.now())
                    saveState()
                    return
                }
                Ghostty.selectedTabID { [weak self] selected in
                    guard let self else { return }
                    self.state.anchor(
                        sessionID: sessionID, tabID: selected, now: Agent.now())
                    self.log("anchored \(sessionID) -> \(selected ?? "<unknown>") (sampled)")
                    self.saveState()
                }
            }

        case .ping:
            log("pong")
        }
    }

    /// Restores the shell watcher's "already staring at it" clear.
    ///
    /// No activation event ever fires when the user watched the round finish in
    /// the session's own tab, because Ghostty never stopped being frontmost — so
    /// without this the notification would sit there until a prompt or a click.
    ///
    /// The notification is posted first and only its expiry is shortened, rather
    /// than suppressed outright: the shell path played the sound and then
    /// removed the banner about a second later, and swallowing the request
    /// entirely would take the audible cue with it. Three seconds is the grace
    /// Ghostty itself uses for a notification raised on an already-focused
    /// surface, and posting first keeps the banner immediate — the Apple Event
    /// happens after delivery, never in front of it.
    private func shortenIfAlreadyWatching(_ notify: NotifyRequest) {
        guard notify.clearOnFocus,
            frontmostIsGhostty,
            let tabID = state.sessions[notify.sessionID]?.tabID
        else { return }

        let identifier = SessionState.notificationID(sessionID: notify.sessionID)
        Ghostty.selectedTabID { [weak self] selected in
            guard let self, let selected, selected == tabID else { return }
            self.log("\(notify.sessionID) is already on screen; clearing in short order")
            self.scheduleExpiry(identifier: identifier, after: Agent.watchedGraceSeconds)
        }
    }

    private static let watchedGraceSeconds: Double = 3

    private func deliver(_ notify: NotifyRequest) {
        let identifier = state.newNotification(
            sessionID: notify.sessionID, clearOnFocus: notify.clearOnFocus, now: Agent.now())
        notifier.post(identifier: identifier, sessionID: notify.sessionID, request: notify)
        log("posted \(identifier)")
        scheduleExpiry(identifier: identifier, after: notify.timeout)
        saveState()
    }

    /// Mirrors the shell path's `--timeout`: without it a notification for a
    /// session the user never returns to would sit in Notification Center until
    /// the 24h prune, rather than the documented GHOSTTY_NOTIFY_TIMEOUT.
    private func scheduleExpiry(identifier: String, after seconds: Double?) {
        expiryTimers.removeValue(forKey: identifier)?.cancel()
        guard let seconds, seconds > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + seconds, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.expiryTimers.removeValue(forKey: identifier)
                guard let sessionID = self.state.sessionID(forNotification: identifier) else {
                    return
                }
                let identifiers = self.state.takeNotifications(sessionID: sessionID)
                self.notifier.withdraw(identifiers)
                self.log("expired \(identifier)")
                self.saveState()
            }
        }
        timer.resume()
        expiryTimers[identifier] = timer
    }

    private func cancelExpiry(_ identifiers: [String]) {
        for identifier in identifiers {
            expiryTimers.removeValue(forKey: identifier)?.cancel()
        }
    }

    // MARK: - Focus

    private var frontmostIsGhostty: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            == AgentConstants.ghosttyBundleID
    }

    /// The replacement for the shell version's one-second poll loop. macOS tells
    /// us when an app comes forward; between events this process is idle and
    /// spawns nothing.
    private func observeActivation() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Reduce to a Sendable value before crossing: the notification and
            // its NSRunningApplication must not follow us onto the main actor.
            let app =
                notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            MainActor.assumeIsolated {
                self?.activated(bundleID: bundleID)
            }
        }
    }

    private func activated(bundleID: String?) {
        guard bundleID == AgentConstants.ghosttyBundleID else { return }
        withdrawForGhostty(retriesLeft: 1)
    }

    private func withdrawForGhostty(retriesLeft: Int) {
        // Cheap guard first. Asking Ghostty which tab is selected is an Apple
        // Event round-trip, and the first one raises the Automation consent
        // dialog — neither belongs on a plain Cmd-Tab with nothing on screen.
        guard state.hasOutstandingNotifications else { return }

        Ghostty.selectedTabID { [weak self] selected in
            guard let self else { return }
            let identifiers = self.state.takeNotifications(
                for: .ghosttyActivated(selectedTabID: selected))
            if !identifiers.isEmpty {
                self.cancelExpiry(identifiers)
                self.notifier.withdraw(identifiers)
                self.saveState()
                return
            }
            // Ghostty's scripting state can trail the activation by a few
            // milliseconds, so a query issued the instant it comes forward may
            // name the previously selected tab. One retry covers that without
            // reintroducing a poll.
            guard retriesLeft > 0, self.state.hasOutstandingNotifications else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.withdrawForGhostty(retriesLeft: retriesLeft - 1)
            }
        }
    }

    // MARK: - Clicks

    /// The notification center does not promise which thread it delivers a
    /// response on — Ghostty shipped a fix for exactly that hazard (its PR #7531,
    /// point 4). So this stays `nonisolated`, reduces the response to Sendable
    /// values, and hops to the main actor before touching any state.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        let action = response.actionIdentifier
        let sessionID = response.notification.request.content.userInfo["session_id"] as? String
        let finish = UncheckedBox(completionHandler)
        Task { @MainActor in
            self.clicked(identifier: identifier, action: action, sessionID: sessionID)
            finish.value()
        }
    }

    private func clicked(identifier: String, action: String, sessionID: String?) {
        // Fall back to the bookkeeping when userInfo is unavailable, so a click
        // still routes after an upgrade that changed the payload.
        let session = sessionID ?? state.sessionID(forNotification: identifier)
        state.forgetNotification(identifier)
        cancelExpiry([identifier])
        saveState()

        switch action {
        case UNNotificationDismissActionIdentifier:
            // Closing a notification is not a request to go anywhere. The shell
            // version had exactly this bug — alerter's close-button label was
            // matched as an action and phantom-activated Ghostty — which is why
            // tests/test-alerter-dispatch.sh exists.
            log("dismissed \(identifier)")
        case UNNotificationDefaultActionIdentifier, AgentConstants.gotoActionID:
            jump(sessionID: session)
        default:
            log("ignored action \(action) on \(identifier)")
        }
    }

    /// Present the banner even while we are frontmost. As an accessory app we
    /// are never meaningfully "in front", but the notification a user asked for
    /// should not depend on that. Touches no state, so it answers inline.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) ->
            Void
    ) {
        completionHandler([.banner, .sound])
    }

    private func jump(sessionID: String?) {
        // Prefer live bookkeeping, then the id ghostty-tab-save.sh persisted —
        // which survives an agent that lost its state file.
        var tabID = sessionID.flatMap { state.sessions[$0]?.tabID }
        if tabID == nil, let sessionID {
            tabID = Agent.persistedTabID(paths: paths, sessionID: sessionID)
        }
        guard let tabID else {
            // No tab was ever resolved (tmux, unscriptable Ghostty). Front the
            // app so the user is one keystroke away instead of nowhere.
            log("jump: no tab for \(sessionID ?? "<none>"), activating Ghostty")
            Ghostty.activate()
            return
        }
        Ghostty.focus(tabID: tabID) { [weak self] ok in
            guard let self else { return }
            if ok {
                self.log("jump: focused \(tabID)")
            } else {
                self.log("jump: \(tabID) is gone, activating Ghostty")
                Ghostty.activate()
            }
        }
    }

    /// Reads the tab id ghostty-tab-save.sh wrote for a session.
    private static func persistedTabID(paths: AgentPaths, sessionID: String) -> String? {
        guard RequestCodec.isValidSessionID(sessionID) else { return nil }
        let path = paths.sessionTabFile(sessionID: sessionID)
        guard let data = FileManager.default.contents(atPath: path),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tabID = object["tab_id"] as? String,
            !tabID.isEmpty
        else { return nil }
        return tabID
    }

    // MARK: - Housekeeping

    private func startPruning() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 3600, repeating: 3600, leeway: .seconds(300))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let orphaned = self.state.prune(
                    maxAge: AgentConstants.sessionMaxAge, now: Agent.now())
                self.cancelExpiry(orphaned)
                self.notifier.withdraw(orphaned)
                self.saveState()
            }
        }
        timer.resume()
        pruneTimer = timer
    }

    private func writePidFile() {
        try? "\(getpid())\n".write(toFile: paths.pidFile, atomically: true, encoding: .utf8)
    }

    private func publishReadiness(_ granted: Bool) {
        let value = granted ? AgentConstants.readyAuthorized : AgentConstants.readyDenied
        try? (value + "\n").write(toFile: paths.readyFile, atomically: true, encoding: .utf8)
    }

    private func loadState() {
        guard let data = FileManager.default.contents(atPath: paths.state) else { return }
        state = StateCodec.decode(data)
        log("restored \(state.sessions.count) sessions")
    }

    private func saveState() {
        guard let data = try? StateCodec.encode(state) else { return }
        // Atomic: a crash mid-write must not leave bookkeeping that decodes to
        // half a truth. `Data.write(options: .atomic)` handles the
        // does-not-exist-yet case, which replaceItemAt does not.
        try? data.write(to: URL(fileURLWithPath: paths.state), options: [.atomic])
    }

    private static func now() -> Double { Date().timeIntervalSince1970 }

    private func log(_ message: String) {
        AgentLog.append(message, to: paths.log)
    }
}

/// Carries a non-Sendable completion handler across an actor hop. Safe by usage,
/// not by type: each one is called exactly once, on the main actor.
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
