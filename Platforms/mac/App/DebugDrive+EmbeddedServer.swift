#if DEBUG
import FlaccyServerEmbed
import Foundation
import MidgarCore

/// `--embed-server <folder>` starts the in-process Flaccy Server on a folder this sandbox can read, waits for
/// it to run, and writes the status and a one-time enrollment to `Caches/embed-drive.json` so a test can reach it.
/// `--embed-server-stop-after <seconds>` quits the app after a graceful stop.
enum DebugEmbeddedServerDrive {
    private static let outputName = "embed-drive.json"

    static func runIfRequested() {
        guard let folder = DebugDrive.value(after: "--embed-server") else { return }
        let stopAfter = DebugDrive.value(after: "--embed-server-stop-after").flatMap(Double.init)
        Task.detached {
            await run(folder: URL(filePath: folder, directoryHint: .isDirectory), stopAfter: stopAfter)
        }
    }

    private static func run(folder: URL, stopAfter: Double?) async {
        let host = FlaccyServerHost()
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        do {
            let started = try host.start(musicFolder: folder, name: "Embedded Mac")
            MidgarLog.info("EmbedDrive: started, state \(started.state.rawValue)", category: .general)
            let running = try await waitUntilRunning(host)
            let enrollment = try host.enroll()
            try write(status: running, enrollment: enrollment)
            MidgarLog.info(
                "EmbedDrive: running on \(running.addresses.joined(separator: ", ")), \(running.songCount ?? -1) songs",
                category: .general)
            guard let stopAfter else { return }
            try await Task.sleep(for: .seconds(stopAfter))
            try host.stop()
            MidgarLog.info("EmbedDrive: stopped gracefully", category: .general)
        } catch {
            MidgarLog.error("EmbedDrive: failed: \(error.localizedDescription)", category: .general)
        }
    }

    private static func waitUntilRunning(_ host: FlaccyServerHost) async throws -> ServerHostStatus {
        for _ in 0..<600 {
            let status = try host.status()
            if status.state == .error { throw ServerHostError.server(status.lastError ?? "the server failed") }
            if status.state == .running, status.songCount != nil { return status }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ServerHostError.server("the server never ran")
    }

    private static func write(status: ServerHostStatus, enrollment: ServerEnrollment) throws {
        let caches = URL.cachesDirectory.appending(path: outputName)
        let document = ["status": try encoded(status), "enrollment": try encoded(enrollment)]
        try JSONSerialization.data(withJSONObject: document).write(to: caches, options: .atomic)
    }

    private static func encoded<Value: Encodable>(_ value: Value) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
}
#endif
