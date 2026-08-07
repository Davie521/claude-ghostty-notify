import Foundation

/// What the agent remembers about one Claude session.
public struct SessionRecord: Equatable, Sendable {
    /// Ghostty tab id this session lives in, or nil when it could never be
    /// resolved — tmux, a session started while Ghostty was in the background,
    /// or AppleScript being unavailable.
    public var tabID: String?
    /// Identifiers of notifications posted for this session and not yet
    /// withdrawn. At most one in practice, because the identifier is stable per
    /// session so a new notification replaces the previous one.
    public var notificationIDs: [String]
    /// False when the notification was posted with
    /// GHOSTTY_NOTIFY_CLEAR_ON_FOCUS=0: focus must never withdraw it.
    public var clearOnFocus: Bool
    public var updatedAt: Double

    public init(
        tabID: String? = nil,
        notificationIDs: [String] = [],
        clearOnFocus: Bool = true,
        updatedAt: Double = 0
    ) {
        self.tabID = tabID
        self.notificationIDs = notificationIDs
        self.clearOnFocus = clearOnFocus
        self.updatedAt = updatedAt
    }
}

/// Which app just came to the front, and — when it was Ghostty — which tab the
/// user landed on.
public enum FocusEvent: Equatable, Sendable {
    /// Ghostty became frontmost. `selectedTabID` is the selected tab of the
    /// front window, or nil when the Apple Event query failed or Ghostty is not
    /// scriptable.
    case ghosttyActivated(selectedTabID: String?)
    case otherAppActivated
}

/// All session bookkeeping, kept pure so every dismissal rule is testable
/// without a notification center, a run loop, or a live Ghostty.
public struct SessionState: Equatable, Sendable {
    public private(set) var sessions: [String: SessionRecord] = [:]

    public init() {}

    /// One stable identifier per session, which is what gives the shell path's
    /// `-group ghostty-notify-<session>` semantics: re-adding a request with an
    /// identifier that is already delivered *replaces* it, so a session that
    /// stops repeatedly leaves one notification rather than a stack.
    public static func notificationID(sessionID: String) -> String {
        "claude-\(sessionID)"
    }

    /// Point a session at a tab. Passing nil records the session without a tab
    /// rather than clearing a previously resolved one — a failed query must not
    /// downgrade good state.
    public mutating func anchor(sessionID: String, tabID: String?, now: Double) {
        var record = sessions[sessionID] ?? SessionRecord()
        if let tabID, !tabID.isEmpty { record.tabID = tabID }
        record.updatedAt = now
        sessions[sessionID] = record
    }

    /// Register the session's notification as outstanding and return its
    /// identifier. Idempotent: posting again reuses the identifier, so the
    /// notification center replaces rather than stacks.
    public mutating func newNotification(
        sessionID: String, clearOnFocus: Bool = true, now: Double
    ) -> String {
        let id = Self.notificationID(sessionID: sessionID)
        var record = sessions[sessionID] ?? SessionRecord()
        if !record.notificationIDs.contains(id) {
            record.notificationIDs.append(id)
        }
        record.clearOnFocus = clearOnFocus
        record.updatedAt = now
        sessions[sessionID] = record
        return id
    }

    /// Hand back a session's outstanding identifiers and forget them. The
    /// session record itself survives so its resolved tab is not lost.
    public mutating func takeNotifications(sessionID: String) -> [String] {
        guard var record = sessions[sessionID], !record.notificationIDs.isEmpty else {
            return []
        }
        let ids = record.notificationIDs
        record.notificationIDs = []
        sessions[sessionID] = record
        return ids
    }

    /// Drop one identifier — the notification center already removed it,
    /// because the user clicked it.
    public mutating func forgetNotification(_ notificationID: String) {
        for (sessionID, var record) in sessions {
            guard let index = record.notificationIDs.firstIndex(of: notificationID) else {
                continue
            }
            record.notificationIDs.remove(at: index)
            sessions[sessionID] = record
            return
        }
    }

    /// The session a notification identifier belongs to, for routing a click
    /// when the notification's own userInfo is unavailable.
    public func sessionID(forNotification notificationID: String) -> String? {
        sessions.first { $0.value.notificationIDs.contains(notificationID) }?.key
    }

    /// True when any session still has a notification on screen. Cheap, and
    /// worth checking before paying for an Apple Event round-trip.
    public var hasOutstandingNotifications: Bool {
        sessions.values.contains { !$0.notificationIDs.isEmpty }
    }

    /// Sessions that would be withdrawn if Ghostty came forward with this tab
    /// selected. Read-only, so the caller can decide whether the (expensive)
    /// tab query is even worth issuing.
    public func sessionsMatching(selectedTabID: String?) -> [String] {
        sessions.filter { _, record in
            guard !record.notificationIDs.isEmpty, record.clearOnFocus else { return false }
            guard let tabID = record.tabID else { return true }
            guard let selectedTabID else { return false }
            return tabID == selectedTabID
        }
        .keys.sorted()
    }

    /// Identifiers to withdraw in response to a focus change, forgetting them.
    ///
    /// A session with no resolved tab is always withdrawn when Ghostty comes
    /// forward: we cannot localize it, and the user is demonstrably looking at
    /// the terminal. A session with a known tab is withdrawn only on a positive
    /// match — when the tab query fails we leave it alone rather than clear a
    /// notification for a tab the user is not on. A session that opted out of
    /// clear-on-focus is never withdrawn this way at all.
    public mutating func takeNotifications(for event: FocusEvent) -> [String] {
        guard case .ghosttyActivated(let selectedTabID) = event else { return [] }
        // Deterministic order so assertions do not depend on dictionary layout.
        return sessionsMatching(selectedTabID: selectedTabID)
            .flatMap { takeNotifications(sessionID: $0) }
    }

    /// Re-attach an identifier loaded from persisted state, without touching
    /// `updatedAt`.
    mutating func adopt(notificationID: String, sessionID: String) {
        var record = sessions[sessionID] ?? SessionRecord()
        if !record.notificationIDs.contains(notificationID) {
            record.notificationIDs.append(notificationID)
        }
        sessions[sessionID] = record
    }

    mutating func setClearOnFocus(_ value: Bool, sessionID: String) {
        guard var record = sessions[sessionID] else { return }
        record.clearOnFocus = value
        sessions[sessionID] = record
    }

    /// Forget sessions untouched for `maxAge` seconds. Outstanding identifiers
    /// are returned so the caller can withdraw notifications that will never be
    /// dismissed by focus or by a prompt — the session is gone.
    @discardableResult
    public mutating func prune(maxAge: Double, now: Double) -> [String] {
        let stale = sessions.filter { now - $0.value.updatedAt > maxAge }
        guard !stale.isEmpty else { return [] }
        var orphaned: [String] = []
        for sessionID in stale.keys.sorted() {
            orphaned.append(contentsOf: sessions[sessionID]?.notificationIDs ?? [])
            sessions[sessionID] = nil
        }
        return orphaned
    }
}
