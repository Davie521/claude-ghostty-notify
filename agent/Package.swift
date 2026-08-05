// swift-tools-version: 6.0
import PackageDescription

// Two halves, split so the decision-making half is testable without AppKit,
// a notification-center authorization grant, or a running Ghostty:
//   NotifyCore — pure logic: request codec, session bookkeeping, dismissal
//                rules. Synchronous, no side effects, no frameworks.
//   AgentApp   — the resident LSUIElement app: UNUserNotificationCenter,
//                NSWorkspace activation events, in-process Apple Events,
//                spool-directory watching.
//
// The product name is the on-disk binary name and must match
// CFBundleExecutable in the app bundle's Info.plist. Swift module names can't
// contain hyphens, hence the target/path split.
let package = Package(
    name: "ghostty-notify-agent",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ghostty-notify-agent", targets: ["AgentApp"]),
        .library(name: "NotifyCore", targets: ["NotifyCore"]),
    ],
    targets: [
        .target(name: "NotifyCore"),
        .executableTarget(
            name: "AgentApp",
            dependencies: ["NotifyCore"],
            path: "Sources/ghostty-notify-agent"
        ),
        .testTarget(name: "NotifyCoreTests", dependencies: ["NotifyCore"]),
    ]
)
