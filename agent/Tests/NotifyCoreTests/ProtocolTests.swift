import Foundation
import Testing

@testable import NotifyCore

@Suite("Session id validation")
struct SessionIDTests {
    @Test(arguments: [
        "deadbeef-1234-5678-9abc-def012345678",
        "abc123",
        "----",
        "0",
    ])
    func accepted(_ id: String) {
        #expect(RequestCodec.isValidSessionID(id))
    }

    // Session ids become dictionary keys and are embedded in notification
    // identifiers; separators and non-hex bytes have no business there.
    @Test(arguments: [
        "",
        "../escape",
        "has space",
        "semi;colon",
        "zz-not-hex",
        "unicode-é",
    ])
    func rejected(_ id: String) {
        #expect(!RequestCodec.isValidSessionID(id))
    }
}

@Suite("Request decoding")
struct RequestDecodingTests {
    private func decode(_ json: String) throws -> AgentRequest {
        try RequestCodec.decode(Data(json.utf8))
    }

    @Test func notifyCarriesEveryField() throws {
        let request = try decode(
            """
            {"type":"notify","session_id":"dead-beef","title":"Task Complete",
             "subtitle":"auth-refactor — webapp","body":"3 files changed","sound":"Glass"}
            """)
        #expect(
            request
                == .notify(
                    NotifyRequest(
                        sessionID: "dead-beef",
                        title: "Task Complete",
                        subtitle: "auth-refactor — webapp",
                        body: "3 files changed",
                        sound: "Glass"
                    )))
    }

    // A missing subtitle or body is not worth refusing a notification over.
    @Test func notifyToleratesAbsentOptionalStrings() throws {
        let request = try decode(#"{"type":"notify","session_id":"abc","title":"T"}"#)
        guard case .notify(let notify) = request else {
            Issue.record("expected notify, got \(request)")
            return
        }
        #expect(notify.subtitle.isEmpty)
        #expect(notify.body.isEmpty)
        #expect(notify.sound == nil)
    }

    // An explicit empty sound is how a hook asks for a silent notification;
    // it must not become a request for a sound literally named "".
    @Test func emptySoundMeansSilent() throws {
        let request = try decode(#"{"type":"notify","session_id":"abc","title":"T","sound":""}"#)
        guard case .notify(let notify) = request else {
            Issue.record("expected notify, got \(request)")
            return
        }
        #expect(notify.sound == nil)
    }

    @Test func notifyWithoutTitleIsRejected() {
        #expect(throws: RequestDecodeError.missingField("title")) {
            try decode(#"{"type":"notify","session_id":"abc"}"#)
        }
    }

    @Test func notifyWithBadSessionIDIsRejected() {
        #expect(throws: RequestDecodeError.invalidSessionID("../etc")) {
            try decode(#"{"type":"notify","session_id":"../etc","title":"T"}"#)
        }
    }

    @Test func dismissAndAnchorAndPing() throws {
        #expect(try decode(#"{"type":"dismiss","session_id":"abc"}"#) == .dismiss(sessionID: "abc"))
        #expect(try decode(#"{"type":"anchor","session_id":"abc"}"#) == .anchor(sessionID: "abc"))
        #expect(try decode(#"{"type":"ping"}"#) == .ping)
    }

    @Test func unknownTypeIsRejected() {
        #expect(throws: RequestDecodeError.unknownType("selfDestruct")) {
            try decode(#"{"type":"selfDestruct"}"#)
        }
    }

    @Test func missingTypeIsRejected() {
        #expect(throws: RequestDecodeError.missingType) {
            try decode(#"{"session_id":"abc"}"#)
        }
    }

    // A half-written spool file must be dropped, not guessed at.
    @Test(arguments: ["", "not json at all", "[1,2,3]", #"{"type":"noti"#])
    func malformedInputThrows(_ json: String) {
        #expect(throws: (any Error).self) {
            try decode(json)
        }
    }

    @Test func roundTrip() throws {
        let cases: [AgentRequest] = [
            .notify(
                NotifyRequest(
                    sessionID: "abc", title: "T", subtitle: "S", body: "B", sound: "Glass")),
            .notify(NotifyRequest(sessionID: "abc", title: "T")),
            .dismiss(sessionID: "abc"),
            .anchor(sessionID: "abc"),
            .ping,
        ]
        for request in cases {
            #expect(try RequestCodec.decode(RequestCodec.encode(request)) == request)
        }
    }
}
