import Foundation

/// Apple Events to Ghostty, sent in-process.
///
/// `NSAppleScript` compiles and runs inside this process, so none of this forks
/// `osascript` — the whole reason the polling loop moved into a resident app.
/// Every call goes through the main thread (Apple Event dispatch wants a run
/// loop) and every call is allowed to fail: Ghostty may not be running, may not
/// be scriptable, or the user may have denied the Automation prompt. A nil
/// result always means "don't know", never "no".
///
/// Reaching Ghostty at all requires NSAppleEventsUsageDescription in the app
/// bundle's Info.plist; without it macOS denies the event instead of prompting.
enum Ghostty {
    /// Surface the user is looking at right now, as a terminal UUID.
    ///
    /// `focused terminal of selected tab of front window` is Ghostty's own
    /// idiom for "the active context" and resolves splits, which a tab id
    /// cannot.
    @MainActor
    static func focusedTerminalID() -> String? {
        let value = runReturningString(
            """
            tell application "Ghostty"
                return id of focused terminal of selected tab of front window
            end tell
            """)
        guard let value, isPlausibleTerminalID(value) else { return nil }
        return value
    }

    /// Raise the window owning `terminalID` and focus it. Ghostty's `focus`
    /// command does both, unlike `select tab`, which selects inside a
    /// background window and leaves the user staring at an unchanged screen.
    @MainActor
    @discardableResult
    static func focus(terminalID: String) -> Bool {
        // The id comes from persisted state and is interpolated into script
        // source, so a crafted value could otherwise smuggle in `do shell
        // script`. Whitelist first, then escape — either alone would do, but
        // this is the one place where being wrong runs arbitrary code.
        guard isPlausibleTerminalID(terminalID) else { return false }
        let literal = appleScriptLiteral(terminalID)
        return runReturningString(
            """
            tell application "Ghostty"
                repeat with w in every window
                    repeat with t in every terminal of w
                        try
                            if (id of t as text) is \(literal) then
                                focus t
                                return "ok"
                            end if
                        end try
                    end repeat
                end repeat
                return ""
            end tell
            """) == "ok"
    }

    /// Degraded fallback for a click we cannot localize: at least put Ghostty in
    /// front so the user is one keystroke from their session.
    @MainActor
    static func activate() {
        _ = runReturningString(#"tell application "Ghostty" to activate"#)
    }

    /// Ghostty hands out UUID-shaped ids. Anything else is either not from
    /// Ghostty or is an attempt to inject script source.
    static func isPlausibleTerminalID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128
            && id.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    @MainActor
    private static func runReturningString(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if errorInfo != nil { return nil }
        guard let value = result.stringValue, !value.isEmpty else { return nil }
        return value
    }
}
