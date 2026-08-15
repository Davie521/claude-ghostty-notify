import Darwin
import Foundation
import NotifyCore

/// Guards against a second agent.
///
/// Two agents draining one spool split requests arbitrarily — the drain unlinks
/// each file before decoding it, so whichever wakes first takes it — and both
/// write `state.json`, so the loser's bookkeeping is silently clobbered. A
/// notification one instance posted then cannot be withdrawn by the other,
/// because only one of them knows the session.
///
/// Two are easy to end up with: `open -a` reuses a running app (LaunchServices
/// enforces one instance), but launchd starting the binary directly bypasses
/// that rule entirely — and the install flow needs both, because a
/// launchd-exec'd agent cannot obtain notification authorization while an
/// `open`-launched one can.
///
/// The incumbent wins and the newcomer exits cleanly. The LaunchAgent's
/// KeepAlive is set to restart only on a *failed* exit, so this cannot spin.
enum Singleton {
    /// PID of a live agent other than this process, or nil.
    ///
    /// Checked before the app finishes launching, so it must not touch anything
    /// from UserNotifications — reading a file and asking about a process is
    /// safe there, and `UNUserNotificationCenter.current()` is emphatically not.
    static func incumbent(paths: AgentPaths) -> pid_t? {
        guard let text = try? String(contentsOfFile: paths.pidFile, encoding: .utf8),
            let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
            pid > 0, pid != getpid()
        else { return nil }

        // Alive?
        guard kill(pid, 0) == 0 || errno == EPERM else { return nil }

        // And actually us, not a recycled pid belonging to something unrelated.
        // proc_pidpath rather than spawning `ps`: this runs on every launch.
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(decoding: buffer[..<Int(length)], as: UTF8.self)
        guard path == ProcessInfo.processInfo.arguments[0]
            || path.hasSuffix("/ghostty-notify-agent")
        else { return nil }

        return pid
    }
}
