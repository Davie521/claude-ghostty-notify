import Foundation

/// What the agent remembers about one Claude session.
public struct SessionRecord: Equatable, Sendable {
    /// Ghostty terminal (surface) UUID this session lives in, or nil when it
    /// could never be resolved — tmux, a session started while Ghostty was in
    /// the background, or AppleScript being unavailable.
    public var tabID: String?
    /// Identifiers of notifications posted for this session and not yet
    /// withdrawn, oldest first.
    public var notificationIDs: [String]
    public var updatedAt: Double

    public init(tabID: String? = nil, notificationIDs: [String] = [], updatedAt: Double = 0) {
        self.tabID = tabID
        self.notificationIDs = notificationIDs
        self.updatedAt = updatedAt
    }
}

/// Which app just came to the front, and — when it was Ghostty — which surface
/// the user landed on.
public enum FocusEvent: Equatable, Sendable {
    /// Ghostty became frontmost. `selectedTabID` is the focused terminal of the
    /// selected tab, or nil when the Apple Event query failed or Ghostty is not
    /// scriptable.
    case ghosttyActivated(selectedTabID: String?)
    case otherAppActivated
}

/// All session bookkeeping, kept pure so every dismissal rule is testable
/// without a notification center, a run loop, or a live Ghostty.
public struct SessionState: Equatable, Sendable {
    public private(set) var sessions: [String: SessionRecord] = [:]
    /// Monotonic counter behind notification identifiers. Kept in the state
    /// (rather than reading the clock) so identifiers are reproducible in tests.
    public private(set) var sequence: Int = 0

    public init() {}

    /// Identifier scheme: the session id is embedded so a stale identifier can
    /// always be traced back, and the counter keeps repeat notifications for
    /// one session distinct.
    public static func notificationID(sessionID: String, sequence: Int) -> String {
        "claude-\(sessionID)-\(sequence)"
    }

    /// Point a session at a surface. Passing nil records the session without a
    /// surface rather than clearing a previously resolved one — a failed query
    /// must not downgrade good state.
    public mutating func anchor(sessionID: String, tabID: String?, now: Double) {
        var record = sessions[sessionID] ?? SessionRecord()
        if let tabID, !tabID.isEmpty { record.tabID = tabID }
        record.updatedAt = now
        sessions[sessionID] = record
    }

    /// Allocate the next identifier and remember it as outstanding.
    public mutating func newNotification(sessionID: String, now: Double) -> String {
        sequence += 1
        let id = Self.notificationID(sessionID: sessionID, sequence: sequence)
        var record = sessions[sessionID] ?? SessionRecord()
        record.notificationIDs.append(id)
        record.updatedAt = now
        sessions[sessionID] = record
        return id
    }

    /// Hand back a session's outstanding identifiers and forget them. The
    /// session record itself survives so its resolved surface is not lost.
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

    /// Identifiers to withdraw in response to a focus change, forgetting them.
    ///
    /// A session with no resolved surface is always withdrawn when Ghostty
    /// comes forward: we cannot localize it, and the user is demonstrably
    /// looking at the terminal. A session with a known surface is withdrawn
    /// only on a positive match — when the surface query fails we leave it
    /// alone rather than clear a notification for a tab the user is not on.
    public mutating func takeNotifications(for event: FocusEvent) -> [String] {
        guard case .ghosttyActivated(let selectedTabID) = event else { return [] }

        let matched = sessions.filter { _, record in
            guard !record.notificationIDs.isEmpty else { return false }
            guard let tabID = record.tabID else { return true }
            guard let selectedTabID else { return false }
            return tabID == selectedTabID
        }

        // Deterministic order so assertions do not depend on dictionary layout.
        return matched.keys.sorted().flatMap { takeNotifications(sessionID: $0) }
    }

    /// Re-attach an identifier loaded from persisted state, without allocating
    /// a new one or touching `updatedAt`.
    mutating func adopt(notificationID: String, sessionID: String) {
        var record = sessions[sessionID] ?? SessionRecord()
        record.notificationIDs.append(notificationID)
        sessions[sessionID] = record
    }

    /// Never let a restore hand back an identifier the previous run already
    /// used, even if the persisted counter somehow trails the records.
    mutating func bumpSequence(to value: Int) {
        sequence = max(sequence, value)
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
