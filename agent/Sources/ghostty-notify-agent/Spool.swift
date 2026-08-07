import Foundation
import NotifyCore

/// Drops a request into the spool. The bash hooks do this themselves with `mv`;
/// this exists so the install script can ping the agent and so the integration
/// test can drive it without duplicating the atomicity rule.
enum SpoolWriter {
    static func write(json: String, to directory: String) -> Bool {
        guard let data = json.data(using: .utf8) else { return false }
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)

        // `%016ld` — NOT `%016d`, which truncates a 64-bit Int to 32 bits and
        // turns a millisecond stamp into a negative number, whose leading `-`
        // then sorts ahead of every hook-written name.
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let name = String(format: "%016ld-%d.json", stamp, Int(getpid()))
        let temporary = directory + "/." + name + ".tmp"
        let final = directory + "/" + name

        guard FileManager.default.createFile(atPath: temporary, contents: data, attributes: nil)
        else { return false }
        // Rename is what publishes the request: the watcher must never read a
        // partially written file.
        do {
            try FileManager.default.moveItem(atPath: temporary, toPath: final)
            return true
        } catch {
            try? FileManager.default.removeItem(atPath: temporary)
            return false
        }
    }
}

/// Watches the spool directory and hands decoded requests to the agent.
///
/// The transport is a directory of one-JSON-object files made visible by
/// rename, which keeps the hooks pure bash — no client binary, no socket
/// lifetime to manage — and an integration test can drive the whole agent by
/// dropping files. A vnode source on the directory fd fires on the rename, so
/// delivery is event-driven rather than polled.
@MainActor
final class SpoolWatcher {
    private let directory: String
    private let onRequest: (AgentRequest) -> Void
    private let log: (String) -> Void
    private let now: () -> Double
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var sweep: DispatchSourceTimer?

    init(
        directory: String,
        log: @escaping (String) -> Void,
        now: @escaping () -> Double = { Date().timeIntervalSince1970 },
        onRequest: @escaping (AgentRequest) -> Void
    ) {
        self.directory = directory
        self.log = log
        self.now = now
        self.onRequest = onRequest
    }

    func start() {
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
        attach()
        // Requests written while the agent was down are still valid work.
        drain()

        // Backstop. A vnode source is tied to an inode, so if the directory is
        // deleted and recreated (a stale sandbox, a user cleaning up) the watch
        // goes deaf forever. This re-attaches and catches anything missed. It
        // is a readdir on an almost-always-empty directory, not a poll of
        // Ghostty, so the cost the native rewrite was after is preserved.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.descriptor < 0 || !FileManager.default.fileExists(atPath: self.directory) {
                    try? FileManager.default.createDirectory(
                        atPath: self.directory, withIntermediateDirectories: true)
                    self.attach()
                }
                self.drain()
            }
        }
        timer.resume()
        sweep = timer
    }

    private func attach() {
        detach()
        let fd = open(directory, O_EVTONLY)
        guard fd >= 0 else {
            log("cannot watch spool \(directory): errno \(errno)")
            return
        }
        descriptor = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let data = source.data
                if data.contains(.delete) || data.contains(.rename) {
                    // Our inode is gone; the next sweep re-attaches. Drain first
                    // in case the same event also carried a write.
                    self.drain()
                    self.detach()
                    return
                }
                self.drain()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    private func detach() {
        source?.cancel()
        source = nil
        descriptor = -1
    }

    /// Consume every request file. Each file is unlinked *before* it is decoded
    /// so a malformed one is dropped instead of being retried on every wakeup.
    private func drain() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return }

        // Order by modification time, not by name. The filename's timestamp
        // prefix is only second-granular on the bash side (BSD `date` has no
        // %N), so two requests written in the same second would otherwise sort
        // arbitrarily — and `drain` depends on a dismiss never overtaking the
        // notify it cancels. APFS keeps nanosecond mtimes, so this is the real
        // arrival order; the name breaks ties.
        let candidates =
            names
            .filter { $0.hasSuffix(".json") }
            .map { name -> (name: String, path: String, modified: Double) in
                let path = directory + "/" + name
                let attributes = try? fm.attributesOfItem(atPath: path)
                let date = attributes?[.modificationDate] as? Date
                return (name, path, date?.timeIntervalSince1970 ?? 0)
            }
            .sorted { ($0.modified, $0.name) < ($1.modified, $1.name) }

        let cutoff = now() - AgentConstants.staleNotifyAge
        for candidate in candidates {
            let data = try? Data(contentsOf: URL(fileURLWithPath: candidate.path))
            try? fm.removeItem(atPath: candidate.path)
            guard let data else { continue }

            let request: AgentRequest
            do {
                request = try RequestCodec.decode(data)
            } catch {
                log("dropped \(candidate.name): \(error)")
                continue
            }

            // Replaying an old notify posts a banner for a round that finished
            // hours ago; replaying an old dismiss or anchor is harmless and
            // still useful, so only notify has an expiry.
            if case .notify = request, candidate.modified < cutoff {
                log("dropped stale notify \(candidate.name) (queued for too long)")
                continue
            }
            onRequest(request)
        }
    }
}
