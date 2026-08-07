import AppKit
import Foundation
import NotifyCore

// Two modes in one binary so the app bundle stays self-contained:
//
//   ghostty-notify-agent               run as the resident LSUIElement app
//   ghostty-notify-agent --send JSON   queue one request and exit
//
// The hooks do not normally need --send; they write the spool file directly in
// bash. It exists for the install script's liveness ping and for the tests.

let environment = ProcessInfo.processInfo.environment

guard let paths = try? AgentPaths(env: environment) else {
    FileHandle.standardError.write(Data("ghostty-notify-agent: HOME is unset\n".utf8))
    exit(2)
}

let arguments = CommandLine.arguments
if arguments.count >= 2, arguments[1] == "--send" {
    guard arguments.count >= 3 else {
        FileHandle.standardError.write(Data("usage: ghostty-notify-agent --send '<json>'\n".utf8))
        exit(2)
    }
    exit(SpoolWriter.write(json: arguments[2], to: paths.spool) ? 0 : 1)
}

// One agent per machine. See Singleton for why two are easy to get and what
// they break. Checked here, before NSApplication exists, so nothing from
// UserNotifications is touched on a launch that is about to bail out.
if let incumbent = Singleton.incumbent(paths: paths) {
    AgentLog.append("another agent is already running as \(incumbent); exiting", to: paths.log)
    exit(0)
}

// SIGTERM keeps its default disposition on purpose: launchd stops the agent that
// way, and there is nothing to flush that saveState has not already written.
let application = NSApplication.shared
let agent = Agent(paths: paths)
application.delegate = agent
application.setActivationPolicy(.accessory)
application.run()
