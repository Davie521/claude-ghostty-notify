import Foundation

public enum AgentConstants {
    public static let ghosttyBundleID = "com.mitchellh.ghostty"
    /// Category carrying the "Go to tab" button. Registered at launch; every
    /// posted notification references it.
    public static let categoryID = "com.ghostty-notify.session"
    public static let gotoActionID = "goto-tab"
    /// Sessions untouched for this long are forgotten and their leftover
    /// notifications withdrawn.
    public static let sessionMaxAge: Double = 86_400
    /// Requests older than this are dropped instead of replayed. Without it, an
    /// agent that was down all evening posts the whole backlog at once on the
    /// next login — a burst of banners for rounds that finished hours ago.
    /// Dismiss and anchor requests are exempt: replaying them late is harmless
    /// and still useful.
    public static let staleNotifyAge: Double = 300
    /// Written by the agent once the notification authorization answer is
    /// known. The hooks read it to decide whether routing through the agent
    /// would actually display anything.
    public static let readyAuthorized = "authorized"
    public static let readyDenied = "denied"
}

public enum AgentPathsError: Error, Equatable {
    case missingHome
}

/// Every path the agent touches, derived from HOME so the integration test can
/// point the whole agent at a sandbox.
public struct AgentPaths: Equatable, Sendable {
    public let home: String

    public init(env: [String: String]) throws {
        guard let home = env["HOME"], !home.isEmpty else {
            throw AgentPathsError.missingHome
        }
        self.home = home
    }

    public var root: String { home + "/.claude/notifications/ghostty-agent" }
    /// Requests land here as one JSON file each, made visible by rename.
    public var spool: String { root + "/spool" }
    /// Session bookkeeping, so a restart does not orphan live notifications.
    public var state: String { root + "/state.json" }
    /// Written on launch, removed on exit; lets hooks tell "agent is up" from
    /// "agent needs launching" without spawning anything.
    public var pidFile: String { root + "/agent.pid" }
    /// Holds `authorized` or `denied`. A hook that finds anything else must
    /// assume the agent cannot display a notification and use the shell path.
    public var readyFile: String { root + "/ready" }
    public var log: String { root + "/agent.log" }
    /// Where ghostty-tab-save.sh records each session's resolved tab id.
    public func sessionTabFile(sessionID: String) -> String {
        home + "/.claude/notifications/ghostty-sessions/" + sessionID + ".json"
    }
}

/// JSON round-trip for `SessionState`, kept beside the paths because both
/// halves of persistence want to stay testable without a filesystem.
public enum StateCodec {
    private struct Wire: Codable {
        struct Record: Codable {
            var tabID: String?
            var notificationIDs: [String]
            var clearOnFocus: Bool?
            var updatedAt: Double
        }
        var sessions: [String: Record]
    }

    public static func encode(_ state: SessionState) throws -> Data {
        let wire = Wire(
            sessions: state.sessions.mapValues {
                Wire.Record(
                    tabID: $0.tabID,
                    notificationIDs: $0.notificationIDs,
                    clearOnFocus: $0.clearOnFocus,
                    updatedAt: $0.updatedAt)
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(wire)
    }

    /// Corrupt or truncated state is not worth recovering — the agent starts
    /// clean rather than acting on half-decoded bookkeeping.
    public static func decode(_ data: Data) -> SessionState {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else {
            return SessionState()
        }
        var state = SessionState()
        state.restore(
            sessions: wire.sessions.mapValues {
                SessionRecord(
                    tabID: $0.tabID,
                    notificationIDs: $0.notificationIDs,
                    // State written before this field existed predates the
                    // opt-out, so the documented default applies.
                    clearOnFocus: $0.clearOnFocus ?? true,
                    updatedAt: $0.updatedAt)
            }
        )
        return state
    }
}

extension SessionState {
    /// Rehydrate from persisted bookkeeping. Separate from the mutating API so
    /// `sessions` stays read-only to everything else.
    mutating func restore(sessions: [String: SessionRecord]) {
        self = SessionState()
        for (id, record) in sessions {
            self.anchor(sessionID: id, tabID: record.tabID, now: record.updatedAt)
            for notificationID in record.notificationIDs {
                self.adopt(notificationID: notificationID, sessionID: id)
            }
            self.setClearOnFocus(record.clearOnFocus, sessionID: id)
        }
    }
}
