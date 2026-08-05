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
            if !granted {
                // Keep serving anyway: draining the spool stops requests piling
                // up, dismiss/anchor still work, and the user may grant the
                // permission later without restarting us.
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
        log("agent down")
    }

    // MARK: - Requests

    private func handle(_ request: AgentRequest) {
        switch request {
        case .notify(let notify):
            let identifier = state.newNotification(sessionID: notify.sessionID, now: Agent.now())
            notifier.post(
                identifier: identifier, sessionID: notify.sessionID, request: notify)
            log("posted \(identifier)")
            saveState()

        case .dismiss(let sessionID):
            let identifiers = state.takeNotifications(sessionID: sessionID)
            notifier.withdraw(identifiers)
            saveState()

        case .anchor(let sessionID):
            // The hook that sends this fires on UserPromptSubmit, so the user
            // has just typed into their own surface — whatever Ghostty reports
            // as focused belongs to this session.
            state.anchor(
                sessionID: sessionID, tabID: Ghostty.focusedTerminalID(), now: Agent.now())
            log("anchored \(sessionID) -> \(state.sessions[sessionID]?.tabID ?? "<unknown>")")
            saveState()

        case .ping:
            log("pong")
        }
    }

    // MARK: - Focus

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
        let identifiers = state.takeNotifications(
            for: .ghosttyActivated(selectedTabID: Ghostty.focusedTerminalID()))
        if !identifiers.isEmpty {
            notifier.withdraw(identifiers)
            saveState()
            return
        }
        // Ghostty's scripting state can trail the activation by a few
        // milliseconds, so a query issued the instant it comes forward may name
        // the previously selected surface. One retry covers that without
        // reintroducing a poll; if there is nothing outstanding, don't bother.
        guard retriesLeft > 0, hasOutstandingNotifications else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.withdrawForGhostty(retriesLeft: retriesLeft - 1)
        }
    }

    private var hasOutstandingNotifications: Bool {
        state.sessions.values.contains { !$0.notificationIDs.isEmpty }
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
        state.forgetNotification(identifier)
        saveState()

        switch action {
        case UNNotificationDismissActionIdentifier:
            // Closing a notification is not a request to go anywhere. The shell
            // version had exactly this bug — alerter's close-button label was
            // matched as an action and phantom-activated Ghostty — which is why
            // tests/test-alerter-dispatch.sh exists.
            log("dismissed \(identifier)")
        case UNNotificationDefaultActionIdentifier, AgentConstants.gotoActionID:
            jump(sessionID: sessionID)
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
        guard let sessionID, let tabID = state.sessions[sessionID]?.tabID else {
            // No surface was ever resolved (tmux, unscriptable Ghostty). Front
            // the app so the user is one keystroke away instead of nowhere.
            log("jump: no surface for \(sessionID ?? "<none>"), activating Ghostty")
            Ghostty.activate()
            return
        }
        if Ghostty.focus(terminalID: tabID) {
            log("jump: focused \(tabID)")
        } else {
            log("jump: \(tabID) is gone, activating Ghostty")
            Ghostty.activate()
        }
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

    private func loadState() {
        guard let data = FileManager.default.contents(atPath: paths.state) else { return }
        state = StateCodec.decode(data)
        log("restored \(state.sessions.count) sessions")
    }

    private func saveState() {
        guard let data = try? StateCodec.encode(state) else { return }
        // Atomic: a crash mid-write must not leave bookkeeping that decodes to
        // half a truth.
        let temporary = paths.state + ".tmp"
        guard FileManager.default.createFile(atPath: temporary, contents: data) else { return }
        _ = try? FileManager.default.replaceItemAt(
            URL(fileURLWithPath: paths.state), withItemAt: URL(fileURLWithPath: temporary))
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

extension FileManager {
    /// `createFile(atPath:contents:attributes:)` spelled without the optional
    /// dance, so `saveState` reads as one decision.
    fileprivate func createFile(atPath path: String, contents: Data) -> Bool {
        createFile(atPath: path, contents: contents, attributes: nil)
    }
}
