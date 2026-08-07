import AppKit
import Foundation

/// What the menu shows. Gathered fresh each time the menu opens, so it can never
/// display a stale "everything is fine".
struct AgentStatus {
    var authorized: Bool
    /// "alert", "banner", "none", "unknown", or "" before it has been read.
    var alertStyle: String
    var outstandingNotifications: Int
    var trackedSessions: Int

    /// The two states where the agent is running but cannot do its job. Banner
    /// counts: a notification that slides away in five seconds cannot be clicked,
    /// and clicking is the whole jump-to-tab feature.
    var needsAttention: Bool {
        !authorized || alertStyle == "banner" || alertStyle == "none"
    }
}

/// The menu bar item.
///
/// Exists because a background agent with no UI gives the user no way to tell
/// "running and working" from "running and silently useless" — which is exactly
/// the state an unanswered permission prompt, a denied Automation grant, or the
/// Temporary alert style leaves it in. Those are invisible without this.
///
/// Opt out with GHOSTTY_NOTIFY_MENU_BAR=0.
@MainActor
final class MenuBar: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let status: () -> AgentStatus
    private let onShowGuidance: () -> Void
    private let onOpenSettings: () -> Void
    private let onOpenLog: () -> Void

    static func isEnabled(env: [String: String]) -> Bool {
        switch env["GHOSTTY_NOTIFY_MENU_BAR"] {
        case nil: return true
        case let value?:
            return !["0", "false", "no", "off"].contains(value.lowercased())
        }
    }

    init(
        status: @escaping () -> AgentStatus,
        onShowGuidance: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onOpenLog: @escaping () -> Void
    ) {
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.status = status
        self.onShowGuidance = onShowGuidance
        self.onOpenSettings = onOpenSettings
        self.onOpenLog = onOpenLog
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refreshIcon()
    }

    /// Template images so the icon follows the menu bar's light/dark appearance
    /// instead of fighting it.
    private func refreshIcon() {
        let current = status()
        let symbol = current.needsAttention ? "bell.badge" : "bell"
        let image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: current.needsAttention
                ? "Claude notifications need attention" : "Claude notifications")
        image?.isTemplate = true
        item.button?.image = image
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshIcon()
        let current = status()
        menu.removeAllItems()

        menu.addItem(disabled("Claude Ghostty Notify"))
        menu.addItem(.separator())

        menu.addItem(
            disabled(
                current.authorized
                    ? "✓  Notifications allowed"
                    : "⚠  Notifications not allowed"))

        switch current.alertStyle {
        case "alert":
            menu.addItem(disabled("✓  Alert style: Persistent"))
        case "banner":
            // The one problem the user can actually fix, so it is the one item
            // that does something when clicked.
            let fix = NSMenuItem(
                title: "⚠  Alert style: Temporary — fix…",
                action: #selector(openSettings), keyEquivalent: "")
            fix.target = self
            menu.addItem(fix)
        case "none":
            let fix = NSMenuItem(
                title: "⚠  Alerts turned off — fix…",
                action: #selector(openSettings), keyEquivalent: "")
            fix.target = self
            menu.addItem(fix)
        default:
            menu.addItem(disabled("…  Alert style: checking"))
        }

        menu.addItem(.separator())
        menu.addItem(
            disabled(
                current.outstandingNotifications == 1
                    ? "1 notification waiting"
                    : "\(current.outstandingNotifications) notifications waiting"))
        menu.addItem(
            disabled(
                current.trackedSessions == 1
                    ? "1 session tracked"
                    : "\(current.trackedSessions) sessions tracked"))

        menu.addItem(.separator())
        menu.addItem(action("Setup guidance…", #selector(showGuidance)))
        menu.addItem(action("Open log", #selector(openLog)))
        menu.addItem(.separator())
        menu.addItem(action("Quit", #selector(quit)))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        entry.target = self
        return entry
    }

    // MARK: - Actions

    @objc private func showGuidance() { onShowGuidance() }
    @objc private func openSettings() { onOpenSettings() }
    @objc private func openLog() { onOpenLog() }
    @objc private func quit() { NSApp.terminate(nil) }
}
