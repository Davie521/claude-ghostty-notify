import Foundation
import Testing

@testable import WatcherCore

// Every expectation here is transcribed from hooks/ghostty-notify-clear.sh;
// the referenced line numbers are the bash source of truth.

@Suite("Constants")
struct ConstantsTests {
    // clear.sh:203. This is the one value the integration test and the
    // implementation would otherwise share as a single point of failure (the
    // test drives the frontmost-app control file with it), so pin the literal.
    @Test func ghosttyBundleIDLiteral() {
        #expect(WatcherConstants.ghosttyBundleID == "com.mitchellh.ghostty")
    }

    // clear.sh:55-56, kept in sync with GROUP_ID in ghostty-notify.sh.
    @Test func groupIDPrefixLiteral() {
        #expect(WatcherConstants.groupIDPrefix == "ghostty-notify-")
    }

    // clear.sh:229 — DEADLINE = now + NOTIFY_TIMEOUT + 30.
    @Test func deadlineGrace() {
        #expect(WatcherConstants.deadlineGrace == 30)
    }

    // clear.sh:232 — ARM_DEADLINE = now + 15.
    @Test func armGrace() {
        #expect(WatcherConstants.armGrace == 15)
    }
}

@Suite("Session id validation")
struct SessionIDTests {
    // clear.sh:48 — ^[a-fA-F0-9-]+$
    @Test(arguments: [
        "ab12-34ef",
        "0f8e7d6c-1234-5678-9abc-def012345678",
        "----",
        "ABCDEF",
    ])
    func accepts(_ sid: String) {
        #expect(WatcherConfig.isValidSessionID(sid))
    }

    @Test(arguments: [
        "",
        "../etc/passwd",
        "abc/def",
        "sess ion",
        "zz99",
        "ab.12",
    ])
    func rejects(_ sid: String) {
        #expect(!WatcherConfig.isValidSessionID(sid))
    }

    @Test func makeThrowsOnBadSessionID() {
        #expect(throws: WatcherConfigError.invalidSessionID) {
            _ = try WatcherConfig.make(
                sessionID: "../evil", env: ["HOME": "/home/u"], isExecutable: { _ in false }
            )
        }
    }

    @Test func makeThrowsWithoutHome() {
        #expect(throws: WatcherConfigError.missingHome) {
            _ = try WatcherConfig.make(
                sessionID: "abcd", env: [:], isExecutable: { _ in false }
            )
        }
    }
}

@Suite("Env parsing (fail-closed)")
struct EnvParsingTests {
    private func config(_ env: [String: String]) throws -> WatcherConfig {
        var env = env
        env["HOME"] = env["HOME"] ?? "/home/u"
        return try WatcherConfig.make(
            sessionID: "abcd-1234", env: env, isExecutable: { _ in false }
        )
    }

    // clear.sh:58-59 — a non-integer GHOSTTY_NOTIFY_TIMEOUT falls back to 1200.
    @Test(arguments: ["3m", "", "-5", "12.5", "1200s", "abc"])
    func badTimeoutFallsBackTo1200(_ raw: String) throws {
        #expect(try config(["GHOSTTY_NOTIFY_TIMEOUT": raw]).notifyTimeout == 1200)
    }

    @Test func timeoutDefaultsTo1200WhenUnset() throws {
        #expect(try config([:]).notifyTimeout == 1200)
    }

    @Test func validTimeoutIsUsed() throws {
        #expect(try config(["GHOSTTY_NOTIFY_TIMEOUT": "20"]).notifyTimeout == 20)
    }

    // clear.sh:60-61 — POLL accepts decimals, everything else falls back to 1.
    @Test(arguments: ["abc", "", "-1", "0.2.3", ".5", "1e3"])
    func badPollFallsBackTo1(_ raw: String) throws {
        #expect(try config(["GHOSTTY_NOTIFY_FOCUS_POLL": raw]).poll == 1)
    }

    // clear.sh:62-65 — zero parses fine but turns the loop into a CPU-pegging
    // spin, so it fails closed like every other numeric knob.
    @Test(arguments: ["0", "0.0", "00", "0.000"])
    func zeroPollFallsBackTo1(_ raw: String) throws {
        #expect(try config(["GHOSTTY_NOTIFY_FOCUS_POLL": raw]).poll == 1)
    }

    @Test func pollDefaultsTo1WhenUnset() throws {
        #expect(try config([:]).poll == 1)
    }

    // The integration tests drive the loop at POLL=0.2; hard-coding 1s would
    // make them time out.
    @Test func fractionalPollIsAccepted() throws {
        #expect(try config(["GHOSTTY_NOTIFY_FOCUS_POLL": "0.2"]).poll == 0.2)
    }

    @Test func integerPollIsAccepted() throws {
        #expect(try config(["GHOSTTY_NOTIFY_FOCUS_POLL": "3"]).poll == 3)
    }

    // clear.sh:67-72 — set by ghostty-notify.sh only when the alerter backend
    // actually fired. Exactly "1" arms it; everything else leaves it off.
    @Test func expectAlerterRequiresExactlyOne() throws {
        #expect(try config(["GHOSTTY_NOTIFY_EXPECT_ALERTER": "1"]).expectAlerter)
        #expect(try !config([:]).expectAlerter)
        #expect(try !config(["GHOSTTY_NOTIFY_EXPECT_ALERTER": "0"]).expectAlerter)
        #expect(try !config(["GHOSTTY_NOTIFY_EXPECT_ALERTER": ""]).expectAlerter)
        #expect(try !config(["GHOSTTY_NOTIFY_EXPECT_ALERTER": "true"]).expectAlerter)
    }

    @Test func pathsAndGroupDeriveFromHomeAndSession() throws {
        let cfg = try config(["HOME": "/sandbox"])
        #expect(cfg.saveDir == "/sandbox/.claude/notifications/ghostty-sessions")
        #expect(cfg.saveFile == "/sandbox/.claude/notifications/ghostty-sessions/abcd-1234.json")
        #expect(cfg.alerterPidFile
            == "/sandbox/.claude/notifications/ghostty-sessions/abcd-1234.alerter-pid")
        #expect(cfg.watchPidFile
            == "/sandbox/.claude/notifications/ghostty-sessions/abcd-1234.watch-pid")
        #expect(cfg.sentinelFile
            == "/sandbox/.claude/notifications/ghostty-sessions/applescript-unavailable")
        #expect(cfg.groupID == "ghostty-notify-abcd-1234")
    }

    @Test func deadlineIsTimeoutPlusGrace() throws {
        let cfg = try config(["GHOSTTY_NOTIFY_TIMEOUT": "20"])
        #expect(cfg.deadline(startedAt: 1000) == 1050)
    }

    // clear.sh:232 — independent of NOTIFY_TIMEOUT.
    @Test func armDeadlineIsFifteenSecondsFromStart() throws {
        let cfg = try config(["GHOSTTY_NOTIFY_TIMEOUT": "1200"])
        #expect(cfg.armDeadline(startedAt: 1000) == 1015)
    }
}

@Suite("Alerter discovery")
struct AlerterDiscoveryTests {
    private let fixed = [
        "/opt/homebrew/bin/alerter",
        "/usr/local/bin/alerter",
        "/home/u/.local/bin/alerter",
    ]

    // clear.sh:89 — GHOSTTY_NOTIFY_ALERTER wins outright, and is NOT probed for
    // executability (bash only checks -x at call time, in remove_delivered).
    @Test func envOverrideWins() {
        let found = WatcherConfig.findAlerter(
            env: [
                "HOME": "/home/u",
                "PATH": "/usr/bin",
                "GHOSTTY_NOTIFY_ALERTER": "/custom/alerter",
            ],
            isExecutable: { _ in true }
        )
        #expect(found == "/custom/alerter")
    }

    // `:-` semantics (clear.sh:89): an empty override falls back to discovery.
    // Deliberately different from WATCHER_BIN's `-` semantics in the hand-off.
    @Test func emptyEnvOverrideFallsBackToDiscovery() {
        let found = WatcherConfig.findAlerter(
            env: [
                "HOME": "/home/u",
                "PATH": "/sandbox/bin:/usr/bin",
                "GHOSTTY_NOTIFY_ALERTER": "",
            ],
            isExecutable: { $0 == "/sandbox/bin/alerter" }
        )
        #expect(found == "/sandbox/bin/alerter")
    }

    // clear.sh:82 — `command -v` first, in PATH order.
    @Test func pathIsSearchedInOrder() {
        let found = WatcherConfig.findAlerter(
            env: ["HOME": "/home/u", "PATH": "/a:/b"],
            isExecutable: { $0 == "/a/alerter" || $0 == "/b/alerter" }
        )
        #expect(found == "/a/alerter")
    }

    // clear.sh:84 — hooks run with a trimmed PATH, so probe the usual installs.
    // This is also what makes the integration stub in $HOME/.local/bin reachable.
    @Test(arguments: [
        "/opt/homebrew/bin/alerter",
        "/usr/local/bin/alerter",
        "/home/u/.local/bin/alerter",
    ])
    func fixedLocationsAreProbed(_ path: String) {
        let found = WatcherConfig.findAlerter(
            env: ["HOME": "/home/u", "PATH": "/nothing"],
            isExecutable: { $0 == path }
        )
        #expect(found == path)
    }

    @Test func fixedLocationsAreProbedInBashOrder() {
        let found = WatcherConfig.findAlerter(
            env: ["HOME": "/home/u", "PATH": "/nothing"],
            isExecutable: { self.fixed.contains($0) }
        )
        #expect(found == "/opt/homebrew/bin/alerter")
    }

    @Test func pathBeatsFixedLocations() {
        let found = WatcherConfig.findAlerter(
            env: ["HOME": "/home/u", "PATH": "/a"],
            isExecutable: { $0 == "/a/alerter" || self.fixed.contains($0) }
        )
        #expect(found == "/a/alerter")
    }

    @Test func nothingFound() {
        let found = WatcherConfig.findAlerter(
            env: ["HOME": "/home/u", "PATH": "/a"],
            isExecutable: { _ in false }
        )
        #expect(found == nil)
    }
}

@Suite("Alerter dialect probe")
struct AlerterDialectTests {
    // clear.sh:121 — `--help | grep -q -- '--remove'`. Both directions
    // asserted: hard-coding --remove would pass a GNU-only test while silently
    // breaking every pre-26.2 alerter.
    @Test func gnuHelpSelectsDoubleDash() {
        let help = "usage: alerter --title --subtitle --remove --group\n"
        #expect(AlerterDialect.detect(helpText: help) == .gnu)
        #expect(AlerterDialect.detect(helpText: help).removeFlag == "--remove")
    }

    @Test func legacyHelpSelectsSingleDash() {
        let help = "alerter -title <title> -remove <group> -closeLabel <label>\n"
        #expect(AlerterDialect.detect(helpText: help) == .legacy)
        #expect(AlerterDialect.detect(helpText: help).removeFlag == "-remove")
    }

    @Test func emptyHelpSelectsLegacy() {
        #expect(AlerterDialect.detect(helpText: "") == .legacy)
    }
}

@Suite("Pidfile handling")
struct PidfileTests {
    // clear.sh:98, :246 — ^[0-9]+$.
    @Test func parsesNumericPid() {
        #expect(WatcherPidfile.parsePid("4242\n") == 4242)
        #expect(WatcherPidfile.parsePid("4242") == 4242)
    }

    @Test(arguments: ["", "  ", "abc", "-1", "12x", "1 2", " 12"])
    func rejectsNonNumericPid(_ raw: String) {
        #expect(WatcherPidfile.parsePid(raw) == nil)
    }

    @Test func rejectsMissingPid() {
        #expect(WatcherPidfile.parsePid(nil) == nil)
    }

    // clear.sh:91-111 — EVERY pattern must appear in `ps -o command=`. A stale
    // pidfile plus PID reuse must never take down an innocent process, and
    // "any alerter" / "any watcher" is not specific enough: the session id and
    // group id are what make a kill session-scoped.
    @Test func takeoverKillsMatchingWatcher() {
        let target = WatcherPidfile.takeoverKillTarget(
            pidfileContent: "999\n",
            selfPid: 123,
            sessionID: "abcd-1234",
            commandLine: { _ in "/plugin/hooks/bin/ghostty-notify-clear-watcher abcd-1234" }
        )
        #expect(target == 999)
    }

    // The bash watcher must remain killable by the Swift one and vice versa —
    // both carry the marks.
    @Test func takeoverAlsoMatchesTheBashWatcher() {
        let target = WatcherPidfile.takeoverKillTarget(
            pidfileContent: "999",
            selfPid: 123,
            sessionID: "abcd-1234",
            commandLine: { _ in "bash /repo/hooks/ghostty-notify-clear.sh --watch abcd-1234" }
        )
        #expect(target == 999)
    }

    @Test func takeoverSparesAnotherSessionsWatcher() {
        let target = WatcherPidfile.takeoverKillTarget(
            pidfileContent: "999",
            selfPid: 123,
            sessionID: "abcd-1234",
            commandLine: { _ in "/hooks/bin/ghostty-notify-clear-watcher ffff-9999" }
        )
        #expect(target == nil)
    }

    @Test func takeoverSparesUnrelatedCommand() {
        let target = WatcherPidfile.takeoverKillTarget(
            pidfileContent: "999",
            selfPid: 123,
            sessionID: "abcd-1234",
            commandLine: { _ in "/usr/bin/ssh git@github.com" }
        )
        #expect(target == nil)
    }

    // clear.sh:101 — an empty `ps` line means the process is gone.
    @Test func takeoverSparesVanishedProcess() {
        #expect(
            WatcherPidfile.takeoverKillTarget(
                pidfileContent: "999", selfPid: 123, sessionID: "abcd-1234",
                commandLine: { _ in nil }
            ) == nil
        )
        #expect(
            WatcherPidfile.takeoverKillTarget(
                pidfileContent: "999", selfPid: 123, sessionID: "abcd-1234",
                commandLine: { _ in "" }
            ) == nil
        )
    }

    // clear.sh:181 — `[[ "$OLD_WATCHER" != "$$" ]]`.
    @Test func takeoverNeverTargetsSelf() {
        let target = WatcherPidfile.takeoverKillTarget(
            pidfileContent: "123\n",
            selfPid: 123,
            sessionID: "abcd-1234",
            commandLine: { _ in "ghostty-notify-clear-watcher abcd-1234" }
        )
        #expect(target == nil)
    }

    @Test func takeoverIgnoresGarbagePidfile() {
        let target = WatcherPidfile.takeoverKillTarget(
            pidfileContent: "not-a-pid",
            selfPid: 123,
            sessionID: "abcd-1234",
            commandLine: { _ in "ghostty-notify-clear-watcher abcd-1234" }
        )
        #expect(target == nil)
    }

    // clear.sh:136 — the blocking alerter is matched on "alerter" AND the
    // group id it was fired with, so one session's clear cannot kill another's.
    @Test func alerterKillIsGroupScoped() {
        let group = "ghostty-notify-abcd-1234"
        #expect(
            WatcherPidfile.killTarget(
                pidText: "77", patterns: ["alerter", group],
                commandLine: { _ in "/opt/homebrew/bin/alerter --group \(group) --title x" }
            ) == 77
        )
        #expect(
            WatcherPidfile.killTarget(
                pidText: "77", patterns: ["alerter", group],
                commandLine: { _ in "/opt/homebrew/bin/alerter --group ghostty-notify-ffff --title x" }
            ) == nil
        )
        #expect(
            WatcherPidfile.killTarget(
                pidText: "77", patterns: ["alerter", group], commandLine: { _ in "/bin/zsh -l" }
            ) == nil
        )
    }
}
