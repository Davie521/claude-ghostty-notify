import Foundation
import Testing

@testable import NotifyCore

@Suite("Notification bookkeeping")
struct BookkeepingTests {
    @Test func identifiersEmbedSessionAndNeverRepeat() {
        var state = SessionState()
        let first = state.newNotification(sessionID: "abc", now: 1)
        let second = state.newNotification(sessionID: "abc", now: 2)
        let other = state.newNotification(sessionID: "def", now: 3)

        #expect(first == "claude-abc-1")
        #expect(second == "claude-abc-2")
        #expect(other == "claude-def-3")
        #expect(state.sessions["abc"]?.notificationIDs == [first, second])
    }

    @Test func takingNotificationsClearsThemButKeepsTheSurface() {
        var state = SessionState()
        state.anchor(sessionID: "abc", tabID: "TAB-1", now: 1)
        _ = state.newNotification(sessionID: "abc", now: 2)
        _ = state.newNotification(sessionID: "abc", now: 3)

        #expect(state.takeNotifications(sessionID: "abc") == ["claude-abc-1", "claude-abc-2"])
        #expect(state.takeNotifications(sessionID: "abc") == [])
        // Losing the resolved surface would send the next focus event down the
        // app-level fallback path for a session we can actually localize.
        #expect(state.sessions["abc"]?.tabID == "TAB-1")
    }

    // A failed Apple Event query must not erase a surface we already know.
    @Test func anchoringWithNoSurfaceDoesNotClearAKnownOne() {
        var state = SessionState()
        state.anchor(sessionID: "abc", tabID: "TAB-1", now: 1)
        state.anchor(sessionID: "abc", tabID: nil, now: 2)
        #expect(state.sessions["abc"]?.tabID == "TAB-1")
        state.anchor(sessionID: "abc", tabID: "", now: 3)
        #expect(state.sessions["abc"]?.tabID == "TAB-1")
    }

    @Test func anchoringRetargetsASessionThatMoved() {
        var state = SessionState()
        state.anchor(sessionID: "abc", tabID: "TAB-1", now: 1)
        state.anchor(sessionID: "abc", tabID: "TAB-2", now: 2)
        #expect(state.sessions["abc"]?.tabID == "TAB-2")
    }

    // The notification center removes a clicked notification itself, so the
    // agent only has to stop tracking it.
    @Test func forgettingOneClickedNotificationLeavesTheRest() {
        var state = SessionState()
        let first = state.newNotification(sessionID: "abc", now: 1)
        let second = state.newNotification(sessionID: "abc", now: 2)
        state.forgetNotification(first)
        #expect(state.sessions["abc"]?.notificationIDs == [second])
    }

    @Test func forgettingAnUnknownIdentifierIsHarmless() {
        var state = SessionState()
        let only = state.newNotification(sessionID: "abc", now: 1)
        state.forgetNotification("claude-abc-999")
        #expect(state.sessions["abc"]?.notificationIDs == [only])
    }

    @Test func pruningDropsStaleSessionsAndReportsOrphans() {
        var state = SessionState()
        _ = state.newNotification(sessionID: "old", now: 0)
        _ = state.newNotification(sessionID: "fresh", now: 100)

        let orphaned = state.prune(maxAge: 50, now: 100)
        #expect(orphaned == ["claude-old-1"])
        #expect(state.sessions.keys.sorted() == ["fresh"])
    }

    @Test func pruningKeepsSessionsExactlyAtTheBoundary() {
        var state = SessionState()
        _ = state.newNotification(sessionID: "edge", now: 0)
        #expect(state.prune(maxAge: 50, now: 50) == [])
        #expect(state.sessions["edge"] != nil)
    }
}

@Suite("Dismissal on focus")
struct FocusDismissalTests {
    private func stateWithTwoSessions() -> SessionState {
        var state = SessionState()
        state.anchor(sessionID: "aaa", tabID: "TAB-1", now: 1)
        _ = state.newNotification(sessionID: "aaa", now: 1)
        state.anchor(sessionID: "bbb", tabID: "TAB-2", now: 1)
        _ = state.newNotification(sessionID: "bbb", now: 1)
        return state
    }

    @Test func anotherAppComingForwardDismissesNothing() {
        var state = stateWithTwoSessions()
        #expect(state.takeNotifications(for: .otherAppActivated) == [])
        #expect(state.sessions["aaa"]?.notificationIDs.isEmpty == false)
    }

    @Test func onlyTheSessionOnTheSelectedTabIsDismissed() {
        var state = stateWithTwoSessions()
        let dismissed = state.takeNotifications(for: .ghosttyActivated(selectedTabID: "TAB-1"))
        #expect(dismissed == ["claude-aaa-1"])
        // The other tab's notification is still waiting for its own tab.
        #expect(state.sessions["bbb"]?.notificationIDs == ["claude-bbb-2"])
    }

    // tmux and unscriptable-Ghostty sessions have no surface to match against;
    // Ghostty coming forward is the best evidence available that the user is
    // back, and this mirrors the app-level fallback the shell version had.
    @Test func aSessionWithNoKnownSurfaceIsDismissedWheneverGhosttyComesForward() {
        var state = SessionState()
        _ = state.newNotification(sessionID: "ccc", now: 1)
        #expect(
            state.takeNotifications(for: .ghosttyActivated(selectedTabID: "TAB-9"))
                == ["claude-ccc-1"])
    }

    // Losing the surface query is not evidence the user is on the right tab.
    // Clearing a localizable notification here would silently drop it.
    @Test func aFailedSurfaceQueryLeavesLocalizedSessionsAlone() {
        var state = stateWithTwoSessions()
        _ = state.newNotification(sessionID: "ccc", now: 1)  // no surface

        let dismissed = state.takeNotifications(for: .ghosttyActivated(selectedTabID: nil))
        #expect(dismissed == ["claude-ccc-3"])
        #expect(state.sessions["aaa"]?.notificationIDs == ["claude-aaa-1"])
        #expect(state.sessions["bbb"]?.notificationIDs == ["claude-bbb-2"])
    }

    @Test func sessionsWithNothingOutstandingAreNotReported() {
        var state = stateWithTwoSessions()
        _ = state.takeNotifications(sessionID: "aaa")
        #expect(state.takeNotifications(for: .ghosttyActivated(selectedTabID: "TAB-1")) == [])
    }
}

@Suite("State persistence")
struct StatePersistenceTests {
    @Test func roundTripPreservesSurfacesAndOutstandingNotifications() throws {
        var state = SessionState()
        state.anchor(sessionID: "aaa", tabID: "TAB-1", now: 10)
        _ = state.newNotification(sessionID: "aaa", now: 11)
        _ = state.newNotification(sessionID: "bbb", now: 12)

        let restored = StateCodec.decode(try StateCodec.encode(state))
        #expect(restored.sessions["aaa"]?.tabID == "TAB-1")
        #expect(restored.sessions["aaa"]?.notificationIDs == ["claude-aaa-1"])
        #expect(restored.sessions["bbb"]?.notificationIDs == ["claude-bbb-2"])
    }

    // A restart must not hand out an identifier the previous run already used,
    // or the new notification would collide with a live one.
    @Test func restoringNeverReusesAnIdentifier() throws {
        var state = SessionState()
        _ = state.newNotification(sessionID: "aaa", now: 1)
        _ = state.newNotification(sessionID: "aaa", now: 2)

        var restored = StateCodec.decode(try StateCodec.encode(state))
        #expect(restored.newNotification(sessionID: "aaa", now: 3) == "claude-aaa-3")
    }

    @Test(arguments: ["", "{", "null", #"{"sessions":"not a dict"}"#])
    func corruptStateStartsClean(_ text: String) {
        #expect(StateCodec.decode(Data(text.utf8)).sessions.isEmpty)
    }
}

@Suite("Paths")
struct PathsTests {
    @Test func everythingHangsOffHome() throws {
        let paths = try AgentPaths(env: ["HOME": "/tmp/sandbox"])
        #expect(paths.spool == "/tmp/sandbox/.claude/notifications/ghostty-agent/spool")
        #expect(paths.state == "/tmp/sandbox/.claude/notifications/ghostty-agent/state.json")
    }

    @Test func missingHomeIsFatalRatherThanGuessed() {
        #expect(throws: AgentPathsError.missingHome) { try AgentPaths(env: [:]) }
        #expect(throws: AgentPathsError.missingHome) { try AgentPaths(env: ["HOME": ""]) }
    }
}
