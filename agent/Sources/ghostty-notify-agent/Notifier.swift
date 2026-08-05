import Foundation
import NotifyCore
import UserNotifications

/// Thin wrapper over the notification center. Everything here is I/O; the
/// decisions about *which* identifiers to post and withdraw live in
/// `NotifyCore` where they are testable.
///
/// UNUserNotificationCenter refuses to serve a process with no bundle identity,
/// and macOS refuses to grant authorization to a bundle in a temporary
/// directory — verified the hard way. The install script therefore assembles a
/// real .app under the plugin root; see scripts/build-agent.sh.
@MainActor
final class Notifier {
    private let center = UNUserNotificationCenter.current()
    /// Sendable because the notification center's completion handlers run off
    /// the main thread and still need to report failures.
    private let log: @Sendable (String) -> Void

    init(log: @escaping @Sendable (String) -> Void) {
        self.log = log
    }

    /// Registers the "Go to tab" button. `.foreground` is what brings this
    /// (accessory) process forward, which is what earns the Apple Event we send
    /// next the right to reorder Ghostty's windows.
    func registerCategories() {
        let goto = UNNotificationAction(
            identifier: AgentConstants.gotoActionID,
            title: "Go to tab",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: AgentConstants.categoryID,
            actions: [goto],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    func setDelegate(_ delegate: UNUserNotificationCenterDelegate) {
        center.delegate = delegate
    }

    func requestAuthorization(_ completion: @escaping @MainActor (Bool) -> Void) {
        center.requestAuthorization(options: [.alert, .sound]) { [log] granted, error in
            Task { @MainActor in
                if let error {
                    log("authorization error: \(error.localizedDescription)")
                }
                completion(granted)
            }
        }
    }

    func post(identifier: String, sessionID: String, request: NotifyRequest) {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.subtitle = request.subtitle
        content.body = request.body
        content.categoryIdentifier = AgentConstants.categoryID
        // Carried on the notification itself so a click can still be routed to a
        // session after the agent restarted and reloaded its bookkeeping.
        content.userInfo = ["session_id": sessionID]
        if let sound = request.sound {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(sound))
        }

        // trigger: nil delivers immediately.
        let notification = UNNotificationRequest(
            identifier: identifier, content: content, trigger: nil)
        center.add(notification) { [log] error in
            if let error {
                log("post \(identifier) failed: \(error.localizedDescription)")
            }
        }
    }

    func withdraw(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        log("withdrew \(identifiers.joined(separator: ","))")
    }
}
