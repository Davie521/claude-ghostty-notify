// swift-tools-version: 6.0
import PackageDescription

// The clear-on-focus watcher, as a native binary. WatcherCore holds every
// decision the bash watcher makes (ghostty-notify-clear.sh --watch) as pure,
// synchronously testable logic; the executable target is a thin adapter over
// NSWorkspace, timers and subprocesses.
let package = Package(
    name: "ghostty-notify-clear-watcher",
    platforms: [.macOS(.v13)],
    products: [
        .executable(
            name: "ghostty-notify-clear-watcher",
            targets: ["WatcherApp"]
        ),
        .library(name: "WatcherCore", targets: ["WatcherCore"]),
    ],
    targets: [
        .target(name: "WatcherCore"),
        // The product name is what ends up on disk and in `ps -o command=`,
        // which is what bash's kill_if_matches greps for — the target is named
        // separately only because hyphens are not valid Swift module names.
        .executableTarget(
            name: "WatcherApp",
            dependencies: ["WatcherCore"],
            path: "Sources/ghostty-notify-clear-watcher"
        ),
        .testTarget(name: "WatcherCoreTests", dependencies: ["WatcherCore"]),
    ]
)
