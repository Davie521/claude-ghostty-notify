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
    public var log: String { root + "/agent.log" }
}

/// JSON round-trip for `SessionState`, kept beside the paths because both
/// halves of persistence want to stay testable without a filesystem.
public enum StateCodec {
    private struct Wire: Codable {
        struct Record: Codable {
            var tabID: String?
            var notificationIDs: [String]
            var updatedAt: Double
        }
        var sessions: [String: Record]
        var sequence: Int
    }

    public static func encode(_ state: SessionState) throws -> Data {
        let wire = Wire(
            sessions: state.sessions.mapValues {
                Wire.Record(
                    tabID: $0.tabID, notificationIDs: $0.notificationIDs, updatedAt: $0.updatedAt)
            },
            sequence: state.sequence
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
                    tabID: $0.tabID, notificationIDs: $0.notificationIDs, updatedAt: $0.updatedAt)
            },
            sequence: wire.sequence
        )
        return state
    }
}

extension SessionState {
    /// Rehydrate from persisted bookkeeping. Separate from the mutating API so
    /// `sessions` and `sequence` stay read-only to everything else.
    mutating func restore(sessions: [String: SessionRecord], sequence: Int) {
        self = SessionState()
        for (id, record) in sessions {
            self.anchor(sessionID: id, tabID: record.tabID, now: record.updatedAt)
            for notificationID in record.notificationIDs {
                self.adopt(notificationID: notificationID, sessionID: id)
            }
        }
        self.bumpSequence(to: sequence)
    }
}
