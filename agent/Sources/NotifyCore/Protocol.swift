import Foundation

/// Requests the hooks drop into the spool directory, one JSON object per file.
///
/// The wire format is deliberately dumb: a flat JSON object with a `type`
/// discriminator, writable by `jq -n` from a bash hook with no client binary.
/// Decoding is fail-closed — an unparseable or half-written file is dropped
/// rather than guessed at, because the writer's `mv` is what makes a request
/// visible and a partial file therefore means a bug, not a race.
public enum AgentRequest: Equatable, Sendable {
    /// Post a notification for a session.
    case notify(NotifyRequest)
    /// Withdraw every notification belonging to a session. Sent by the
    /// UserPromptSubmit hook: submitting a prompt proves the user is back.
    case dismiss(sessionID: String)
    /// Record that this session lives in whichever Ghostty surface is focused
    /// right now. Sent by UserPromptSubmit too — the user just typed into
    /// their tab, so the focused surface is theirs by construction.
    case anchor(sessionID: String)
    /// Liveness probe used by the install script and the integration test.
    case ping
}

public struct NotifyRequest: Equatable, Sendable {
    public var sessionID: String
    public var title: String
    public var subtitle: String
    public var body: String
    /// Notification sound name; `nil` posts silently.
    public var sound: String?

    public init(
        sessionID: String,
        title: String,
        subtitle: String = "",
        body: String = "",
        sound: String? = nil
    ) {
        self.sessionID = sessionID
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.sound = sound
    }
}

public enum RequestDecodeError: Error, Equatable {
    case notAnObject
    case missingType
    case unknownType(String)
    case missingField(String)
    case invalidSessionID(String)
}

public enum RequestCodec {
    /// Session ids reach us from hook stdin and are used as dictionary keys and
    /// (via the notification identifier) handed to the notification center.
    /// Constrain them to the UUID-ish shape Claude Code emits so nothing
    /// downstream has to defend against separators.
    public static func isValidSessionID(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    public static func decode(_ data: Data) throws -> AgentRequest {
        let raw = try? JSONSerialization.jsonObject(with: data)
        guard let object = raw as? [String: Any] else {
            throw RequestDecodeError.notAnObject
        }
        guard let type = object["type"] as? String, !type.isEmpty else {
            throw RequestDecodeError.missingType
        }

        func session() throws -> String {
            guard let id = object["session_id"] as? String else {
                throw RequestDecodeError.missingField("session_id")
            }
            guard isValidSessionID(id) else {
                throw RequestDecodeError.invalidSessionID(id)
            }
            return id
        }

        // Absent string fields degrade to empty rather than failing: a
        // notification with no subtitle is still worth showing.
        func string(_ key: String) -> String {
            (object[key] as? String) ?? ""
        }

        switch type {
        case "notify":
            let title = string("title")
            guard !title.isEmpty else {
                throw RequestDecodeError.missingField("title")
            }
            // An explicit empty sound means "silent"; an absent key does too.
            let sound = (object["sound"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return .notify(
                NotifyRequest(
                    sessionID: try session(),
                    title: title,
                    subtitle: string("subtitle"),
                    body: string("body"),
                    sound: sound
                )
            )
        case "dismiss":
            return .dismiss(sessionID: try session())
        case "anchor":
            return .anchor(sessionID: try session())
        case "ping":
            return .ping
        default:
            throw RequestDecodeError.unknownType(type)
        }
    }

    /// Round-trip counterpart, used by tests and by `--send` in the agent
    /// binary. Hooks build the same shape with `jq -n`.
    public static func encode(_ request: AgentRequest) throws -> Data {
        var object: [String: Any]
        switch request {
        case .notify(let n):
            object = [
                "type": "notify",
                "session_id": n.sessionID,
                "title": n.title,
                "subtitle": n.subtitle,
                "body": n.body,
            ]
            if let sound = n.sound { object["sound"] = sound }
        case .dismiss(let sessionID):
            object = ["type": "dismiss", "session_id": sessionID]
        case .anchor(let sessionID):
            object = ["type": "anchor", "session_id": sessionID]
        case .ping:
            object = ["type": "ping"]
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
