import Foundation
import Testing

@testable import WatcherCore

private let farDeadline = 1_000_000.0

private func exactTabMachine(tab: String = "tab-42") -> WatcherStateMachine {
    WatcherStateMachine(mode: .exactTab(tab), deadline: farDeadline)
}

private func fallbackMachine() -> WatcherStateMachine {
    WatcherStateMachine(mode: .fallback, deadline: farDeadline)
}

// Convenience: a tick with no alerter pidfile on disk, which is the state the
// terminal-notifier backend leaves behind (clear.sh:241-243).
private func tick(_ m: WatcherStateMachine, _ now: Double = 0, _ alerter: AlerterState = .missing)
    -> WatcherEffect
{
    m.tick(TickInput(now: now, alerter: alerter))
}

@Suite("Mode snapshot")
struct ModeResolutionTests {
    // clear.sh:184-190 — tab_id from the save file, unless the sentinel stands.
    @Test func tabIDSelectsExactTabMode() {
        let json = Data(#"{"tab_id":"tab-42","cwd":"/tmp"}"#.utf8)
        #expect(
            WatcherStateMachine.resolveMode(saveFileJSON: json, sentinelExists: false)
                == .exactTab("tab-42")
        )
    }

    // ghostty-tab-save.sh:206 writes an empty tab_id after 3 failed attempts.
    @Test func emptyTabIDSelectsFallback() {
        let json = Data(#"{"tab_id":"","cwd":"/tmp"}"#.utf8)
        #expect(
            WatcherStateMachine.resolveMode(saveFileJSON: json, sentinelExists: false) == .fallback
        )
    }

    @Test func missingTabIDKeySelectsFallback() {
        let json = Data(#"{"cwd":"/tmp"}"#.utf8)
        #expect(
            WatcherStateMachine.resolveMode(saveFileJSON: json, sentinelExists: false) == .fallback
        )
    }

    @Test func corruptSaveFileSelectsFallback() {
        let json = Data("{not json at all".utf8)
        #expect(
            WatcherStateMachine.resolveMode(saveFileJSON: json, sentinelExists: false) == .fallback
        )
    }

    @Test func missingSaveFileSelectsFallback() {
        #expect(
            WatcherStateMachine.resolveMode(saveFileJSON: nil, sentinelExists: false) == .fallback
        )
    }

    // clear.sh:190 — the standing unscriptable-Ghostty sentinel wins over a
    // perfectly good tab_id.
    @Test func sentinelForcesFallbackEvenWithTabID() {
        let json = Data(#"{"tab_id":"tab-42"}"#.utf8)
        #expect(
            WatcherStateMachine.resolveMode(saveFileJSON: json, sentinelExists: true) == .fallback
        )
    }

    // The mode is a startup snapshot: ghostty-tab-save.sh:138 can create the
    // sentinel mid-flight, and re-reading it every tick would diverge from bash.
    @Test func modeIsImmutableAcrossTicks() {
        let m = exactTabMachine()
        m.noteFrontmost(.other)
        _ = tick(m, 1)
        _ = tick(m, 2)
        #expect(m.mode == .exactTab("tab-42"))
    }
}

@Suite("Exact-tab mode")
struct ExactTabTests {
    // clear.sh:19-21, :262-265 — the cheap frontmost gate: no AppleScript
    // unless Ghostty is actually frontmost.
    @Test func backgroundGhosttyNeverQueriesTheTab() {
        let m = exactTabMachine()
        m.noteFrontmost(.other)
        #expect(tick(m, 1) == .none)
        m.noteFrontmost(.unknown)
        #expect(tick(m, 2) == .none)
    }

    @Test func frontmostGhosttyQueriesTheTab() {
        let m = exactTabMachine()
        m.noteFrontmost(.ghostty)
        #expect(tick(m, 1) == .queryTab(tabID: "tab-42"))
    }

    // One AppleScript in flight at a time.
    @Test func doesNotQueueASecondQueryWhileOneIsInFlight() {
        let m = exactTabMachine()
        m.noteFrontmost(.ghostty)
        #expect(tick(m, 1) == .queryTab(tabID: "tab-42"))
        #expect(tick(m, 2) == .none)
    }

    // clear.sh:265-269 — a different selected tab must not clear.
    @Test func wrongTabDoesNotClearAndIsRetried() {
        let m = exactTabMachine()
        m.noteFrontmost(.ghostty)
        #expect(tick(m, 1) == .queryTab(tabID: "tab-42"))
        m.noteTabQueryResult(false)
        #expect(tick(m, 2) == .queryTab(tabID: "tab-42"))
        #expect(!m.isFinished)
    }

    @Test func matchingTabClears() {
        let m = exactTabMachine()
        m.noteFrontmost(.ghostty)
        _ = tick(m, 1)
        m.noteTabQueryResult(true)
        #expect(tick(m, 2) == .clearAndExit)
        #expect(m.isFinished)
    }

    // clear.sh:22-24 — "already staring at it" clears immediately; unlike the
    // fallback path it does not need Ghostty to have been away first.
    @Test func clearsOnTheFirstRoundTripWhenAlreadyOnTheTab() {
        let m = exactTabMachine()
        m.noteFrontmost(.ghostty)
        #expect(tick(m, 1) == .queryTab(tabID: "tab-42"))
        m.noteTabQueryResult(true)
        #expect(tick(m, 1) == .clearAndExit)
    }

    // A "yes" that arrives after the user already switched away is stale.
    @Test func leavingGhosttyDiscardsAPendingResult() {
        let m = exactTabMachine()
        m.noteFrontmost(.ghostty)
        _ = tick(m, 1)
        m.noteTabQueryResult(true)
        m.noteFrontmost(.other)
        #expect(tick(m, 2) == .none)
        m.noteFrontmost(.ghostty)
        #expect(tick(m, 3) == .queryTab(tabID: "tab-42"))
    }

    @Test func effectsStopAfterFinishing() {
        let m = exactTabMachine()
        m.noteFrontmost(.ghostty)
        _ = tick(m, 1)
        m.noteTabQueryResult(true)
        #expect(tick(m, 2) == .clearAndExit)
        m.noteTabQueryResult(true)
        #expect(tick(m, 3) == .none)
    }
}

@Suite("App-level fallback mode")
struct FallbackTests {
    // clear.sh:25-29, :270-275 — rising edge only.
    @Test func clearsWhenGhosttyBecomesFrontmost() {
        let m = fallbackMachine()
        m.noteFrontmost(.other)
        #expect(tick(m, 1) == .none)
        m.noteFrontmost(.ghostty)
        #expect(tick(m, 2) == .clearAndExit)
    }

    @Test func alreadyFrontmostAtFireTimeDoesNotClear() {
        let m = fallbackMachine()
        m.noteFrontmost(.ghostty)
        #expect(tick(m, 1) == .none)
        #expect(tick(m, 2) == .none)
        #expect(tick(m, 3) == .none)
        #expect(!m.isFinished)
    }

    @Test func clearsAfterLeavingAndComingBack() {
        let m = fallbackMachine()
        m.noteFrontmost(.ghostty)
        #expect(tick(m, 1) == .none)
        m.noteFrontmost(.other)
        #expect(tick(m, 2) == .none)
        m.noteFrontmost(.ghostty)
        #expect(tick(m, 3) == .clearAndExit)
    }

    @Test func neverRunsAppleScript() {
        let m = fallbackMachine()
        m.noteFrontmost(.ghostty)
        #expect(tick(m, 1) == .none)
        m.noteFrontmost(.other)
        _ = tick(m, 2)
        m.noteFrontmost(.ghostty)
        #expect(tick(m, 3) == .clearAndExit)
    }

    // clear.sh:192-195, :276 — a frontmost check that could not tell must NOT
    // read as "the user left Ghostty", or it arms the rising edge and clears
    // an alert nobody saw.
    @Test func unknownFrontmostDoesNotArmTheRisingEdge() {
        let m = fallbackMachine()
        m.noteFrontmost(.ghostty)
        #expect(tick(m, 1) == .none)
        m.noteFrontmost(.unknown)
        #expect(tick(m, 2) == .none)
        #expect(tick(m, 3) == .none)
        m.noteFrontmost(.ghostty)
        #expect(tick(m, 4) == .none)
        #expect(!m.isFinished)
    }

    @Test func unknownFrontmostDoesNotDisarmARealEdge() {
        let m = fallbackMachine()
        m.noteFrontmost(.other)
        #expect(tick(m, 1) == .none)
        m.noteFrontmost(.unknown)
        #expect(tick(m, 2) == .none)
        m.noteFrontmost(.ghostty)
        #expect(tick(m, 3) == .clearAndExit)
    }
}

@Suite("Alerter lifecycle")
struct AlerterLifecycleTests {
    // clear.sh:244-252. The pidfile is written by ghostty-notify.sh's
    // backgrounded subshell and can appear after the watcher starts.
    @Test func pidfileArrivingLateIsPickedUp() {
        let m = fallbackMachine()
        m.noteFrontmost(.other)
        #expect(tick(m, 1, .missing) == .none)
        #expect(tick(m, 2, .alive(4242)) == .none)
        #expect(tick(m, 3, .missing) == .exitSilently)
        #expect(m.isFinished)
    }

    @Test func liveAlerterThatDiesExitsSilently() {
        let m = fallbackMachine()
        m.noteFrontmost(.other)
        #expect(tick(m, 1, .alive(4242)) == .none)
        #expect(tick(m, 2, .dead(4242)) == .exitSilently)
    }

    // First observation already dead — clear.sh sets SAW then `kill -0` fails.
    @Test func alerterDeadOnFirstObservationExitsSilently() {
        let m = fallbackMachine()
        m.noteFrontmost(.other)
        #expect(tick(m, 1, .dead(4242)) == .exitSilently)
    }

    // clear.sh:246 — only ^[0-9]+$ counts; garbage neither latches nor exits.
    @Test func unreadablePidfileIsIgnored() {
        let m = fallbackMachine()
        m.noteFrontmost(.other)
        #expect(tick(m, 1, .unreadable) == .none)
        #expect(tick(m, 2, .missing) == .none)
        #expect(!m.isFinished)
    }

    @Test func unreadablePidfileThatTurnsNumericIsTracked() {
        let m = fallbackMachine()
        m.noteFrontmost(.other)
        #expect(tick(m, 1, .unreadable) == .none)
        #expect(tick(m, 2, .alive(4242)) == .none)
        #expect(tick(m, 3, .missing) == .exitSilently)
    }

    // terminal-notifier writes no pidfile — that watcher just runs to deadline.
    @Test func pidfileThatNeverAppearsRunsToDeadline() {
        let m = WatcherStateMachine(mode: .fallback, deadline: 100)
        m.noteFrontmost(.other)
        #expect(tick(m, 10, .missing) == .none)
        #expect(tick(m, 99, .missing) == .none)
        #expect(tick(m, 100, .missing) == .exitSilently)
    }

    // clear.sh:244 runs before :262 — a gone alerter has nothing left to clear,
    // so the silent exit wins over a clear that would fire in the same tick.
    @Test func alerterGoneBeatsExactTabClearInTheSameTick() {
        let m = exactTabMachine()
        m.noteFrontmost(.ghostty)
        _ = tick(m, 1, .alive(4242))
        m.noteTabQueryResult(true)
        #expect(tick(m, 2, .missing) == .exitSilently)
    }

    @Test func alerterGoneBeatsFallbackClearInTheSameTick() {
        let m = fallbackMachine()
        m.noteFrontmost(.other)
        _ = tick(m, 1, .alive(4242))
        m.noteFrontmost(.ghostty)
        #expect(tick(m, 2, .dead(4242)) == .exitSilently)
    }
}

@Suite("Arming gate")
struct ArmingGateTests {
    private func armed(mode: WatchMode, armDeadline: Double = 15) -> WatcherStateMachine {
        WatcherStateMachine(
            mode: mode, deadline: farDeadline, armDeadline: armDeadline, expectAlerter: true
        )
    }

    // clear.sh:254-260 — the alerter runs in a backgrounded subshell, so under
    // scheduling delay the first poll can beat delivery. Clearing then removes
    // nothing and exits, leaving the alert that lands a moment later unwatched.
    @Test func exactTabWaitsForDeliveryBeforeQuerying() {
        let m = armed(mode: .exactTab("tab-42"))
        m.noteFrontmost(.ghostty)
        #expect(tick(m, 1, .missing) == .none)
        #expect(tick(m, 2, .missing) == .none)
    }

    @Test func fallbackWaitsForDeliveryBeforeClearing() {
        let m = armed(mode: .fallback)
        m.noteFrontmost(.other)
        #expect(tick(m, 1, .missing) == .none)
        m.noteFrontmost(.ghostty)
        #expect(tick(m, 2, .missing) == .none)
        #expect(!m.isFinished)
    }

    @Test func aDeliveredAlerterOpensTheGate() {
        let m = armed(mode: .exactTab("tab-42"))
        m.noteFrontmost(.ghostty)
        #expect(tick(m, 1, .missing) == .none)
        #expect(tick(m, 2, .alive(4242)) == .queryTab(tabID: "tab-42"))
    }

    // The gate is time-boxed: an alerter that can never register its PID
    // (mktemp failure in ghostty-notify.sh) must not disable the watcher.
    @Test func gateExpiresAtTheArmDeadline() {
        let m = armed(mode: .exactTab("tab-42"), armDeadline: 15)
        m.noteFrontmost(.ghostty)
        #expect(tick(m, 14, .missing) == .none)
        #expect(tick(m, 15, .missing) == .queryTab(tabID: "tab-42"))
    }

    // While the gate is closed the frontmost sample is still skipped entirely,
    // exactly like the bash `continue` — so no rising edge is armed from it.
    @Test func closedGateDoesNotArmTheRisingEdge() {
        let m = armed(mode: .fallback, armDeadline: 15)
        m.noteFrontmost(.other)
        #expect(tick(m, 1, .missing) == .none)
        m.noteFrontmost(.ghostty)
        #expect(tick(m, 16, .alive(4242)) == .none)
        #expect(!m.isFinished)
    }

    // The gate never applies when the terminal-notifier backend fired: no
    // pidfile is ever coming (clear.sh:67-72 only sets it for alerter).
    @Test func gateIsInactiveWithoutExpectAlerter() {
        let m = WatcherStateMachine(
            mode: .fallback, deadline: farDeadline, armDeadline: 15, expectAlerter: false
        )
        m.noteFrontmost(.other)
        #expect(tick(m, 1, .missing) == .none)
        m.noteFrontmost(.ghostty)
        #expect(tick(m, 2, .missing) == .clearAndExit)
    }

    // The alerter-lifecycle check runs BEFORE the gate (clear.sh:244 vs :256),
    // so a dead alerter still ends the watcher even while the gate is closed.
    @Test func alerterLifecycleStillRunsWhileTheGateIsClosed() {
        let m = armed(mode: .fallback)
        m.noteFrontmost(.other)
        #expect(tick(m, 1, .dead(4242)) == .exitSilently)
    }
}

@Suite("Deadline")
struct DeadlineTests {
    // clear.sh:236 — `while (( now < DEADLINE ))`, so the deadline tick itself
    // no longer runs the body.
    @Test func exitsSilentlyAtTheDeadline() {
        let m = exactTabMachine()
        m.noteFrontmost(.ghostty)
        #expect(tick(m, 99) == .queryTab(tabID: "tab-42"))
        #expect(WatcherStateMachine(mode: .fallback, deadline: 100).tick(
            TickInput(now: 100, alerter: .missing)
        ) == .exitSilently)
    }

    @Test func deadlineBeatsAPendingClear() {
        let m = WatcherStateMachine(mode: .exactTab("tab-42"), deadline: 100)
        m.noteFrontmost(.ghostty)
        _ = tick(m, 1)
        m.noteTabQueryResult(true)
        #expect(tick(m, 101) == .exitSilently)
    }
}
