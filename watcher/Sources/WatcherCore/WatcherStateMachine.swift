import Foundation

/// Which clear condition this watcher is waiting for. Decided once, at
/// startup: ghostty-tab-save.sh:138 can drop the unscriptable-Ghostty sentinel
/// mid-flight, and re-reading it every tick would diverge from bash, which
/// snapshots both inputs at ghostty-notify-clear.sh:144-148.
public enum WatchMode: Sendable, Equatable {
    case exactTab(String)
    case fallback
}

/// What the `<sid>.alerter-pid` file looked like this tick. The adapter does
/// the reading and the `kill -0`; the distinction between "absent" and
/// "present but not a number" matters because bash only treats the former as
/// evidence that a previously seen alerter has gone away.
public enum AlerterState: Sendable, Equatable {
    case missing
    case unreadable
    case alive(Int32)
    case dead(Int32)
}

/// Three-valued, mirroring ghostty_front_state (clear.sh:192-206). "Could not
/// tell" is not "the user left Ghostty": in fallback mode that distinction is
/// what stops a transient probe failure from arming the rising edge and
/// clearing an alert nobody saw.
public enum FrontState: Sendable, Equatable {
    case ghostty
    case other
    case unknown
}

public struct TickInput: Sendable, Equatable {
    public let now: Double
    public let alerter: AlerterState

    public init(now: Double, alerter: AlerterState = .missing) {
        self.now = now
        self.alerter = alerter
    }
}

public enum WatcherEffect: Sendable, Equatable {
    case none
    case queryTab(tabID: String)
    case clearAndExit
    case exitSilently
}

/// One tick of ghostty-notify-clear.sh's watch loop, minus every side effect.
///
/// Frontmost state is pushed in out-of-band but is only *acted on* at tick
/// boundaries, so the fallback rising edge behaves exactly like the polled
/// bash version. Likewise the AppleScript tab answer
/// is latched and consumed by the next tick, which keeps bash's ordering
/// guarantee that the alerter-lifecycle check (clear.sh:185) runs before the
/// clear decision (clear.sh:195) — the adapter simply runs an extra tick as
/// soon as an answer lands so nothing waits a full poll interval for it.
///
/// Not thread-safe by construction: the adapter confines every call to one
/// serial queue.
public final class WatcherStateMachine: @unchecked Sendable {
    public let mode: WatchMode
    public let deadline: Double
    public let armDeadline: Double
    public let expectAlerter: Bool
    public private(set) var isFinished = false

    private var front: FrontState = .unknown
    private var sawGhosttyAway = false
    private var sawAlerterPid = false
    private var tabQueryInFlight = false
    private var pendingTabSelected: Bool?

    public init(
        mode: WatchMode,
        deadline: Double,
        armDeadline: Double = -.infinity,
        expectAlerter: Bool = false
    ) {
        self.mode = mode
        self.deadline = deadline
        self.armDeadline = armDeadline
        self.expectAlerter = expectAlerter
    }

    /// ghostty-notify-clear.sh:144-148.
    public static func resolveMode(saveFileJSON: Data?, sentinelExists: Bool) -> WatchMode {
        guard !sentinelExists,
              let saveFileJSON,
              let root = try? JSONSerialization.jsonObject(with: saveFileJSON) as? [String: Any],
              // ghostty-tab-save.sh always writes tab_id as a JSON string.
              let tabID = root["tab_id"] as? String,
              !tabID.isEmpty
        else { return .fallback }
        return .exactTab(tabID)
    }

    public func noteFrontmost(_ state: FrontState) {
        front = state
    }

    public func noteTabQueryResult(_ selected: Bool) {
        tabQueryInFlight = false
        pendingTabSelected = selected
    }

    public func tick(_ input: TickInput) -> WatcherEffect {
        guard !isFinished else { return .none }

        // `while (( $(date +%s) < DEADLINE ))` (clear.sh:179): the deadline
        // tick no longer runs the body.
        if input.now >= deadline { return finish(.exitSilently) }

        // Notification lifecycle first (clear.sh:185-193). Once the blocking
        // alerter has been seen and is gone there is nothing left to clear, so
        // this outranks any clear that would fire in the same tick.
        switch input.alerter {
        case .alive:
            sawAlerterPid = true
        case .dead:
            sawAlerterPid = true
            return finish(.exitSilently)
        case .unreadable:
            break
        case .missing:
            if sawAlerterPid { return finish(.exitSilently) }
        }

        // Arming gate (clear.sh:254-260). The alerter fires from a backgrounded
        // subshell, so under scheduling delay the first poll can beat delivery;
        // clearing then removes nothing and exits, leaving the alert that lands
        // a moment later unwatched. Bash `continue`s here, skipping the
        // frontmost sample entirely — so no rising edge is armed either.
        if expectAlerter, !sawAlerterPid, input.now < armDeadline { return .none }

        // Cheap frontmost gate (clear.sh:19-21, :262-265): no AppleScript
        // unless Ghostty is actually frontmost.
        switch front {
        case .other:
            sawGhosttyAway = true
            // An answer that arrives after the user switched away is stale.
            pendingTabSelected = nil
            return .none
        case .unknown:
            return .none
        case .ghostty:
            break
        }

        switch mode {
        case .exactTab(let tabID):
            let answer = pendingTabSelected
            pendingTabSelected = nil
            if answer == true { return finish(.clearAndExit) }
            guard !tabQueryInFlight else { return .none }
            tabQueryInFlight = true
            return .queryTab(tabID: tabID)

        case .fallback:
            // Rising edge only (clear.sh:25-29): Ghostty already frontmost when
            // the alert fired means the user may be in another tab entirely.
            guard sawGhosttyAway else { return .none }
            return finish(.clearAndExit)
        }
    }

    private func finish(_ effect: WatcherEffect) -> WatcherEffect {
        isFinished = true
        return effect
    }
}
