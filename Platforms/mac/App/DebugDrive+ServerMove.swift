import MidgarCore
#if DEBUG
import AppKit
import FlaccyCore
import FlaccyEngine

/// `--shot-server-move` with `FLACCY_SHOT_SERVER=<flaccy://server link>` and a library folder holding `MoveExercise/` as the
/// iPhone exercise lays it out: connects through the real setup path, lets the merge summary and the one-time offer open as
/// they do for a person, and captures the offer, the server's sheet with its On This Mac row, and the result of moving with
/// loved songs kept. Logs `SERVER MOVE SHOT DONE` or `SERVER MOVE SHOT FAILED: <step>`.
enum DebugServerMoveDrive {

    private struct Failure: Error {
        let step: String
    }

    static func runIfRequested(window: NSWindow?) {
        guard CommandLine.arguments.contains("--shot-server-move") else { return }
        if CommandLine.arguments.contains("--skip-keychain") { RemoteCredentialStore.shared.useMemoryBackend() }
        Task {
            do {
                try await drive(window: window)
                MidgarLog.info("SERVER MOVE SHOT DONE", category: .general)
            } catch let failure as Failure {
                MidgarLog.error("SERVER MOVE SHOT FAILED: \(failure.step)", category: .general)
            } catch {
                MidgarLog.error("SERVER MOVE SHOT FAILED: \(error.localizedDescription)", category: .general)
            }
        }
    }

    private static func drive(window: NSWindow?) async throws {
        guard let window, let host = window.contentViewController else { throw Failure(step: "the main window is up") }
        let text = ProcessInfo.processInfo.environment["FLACCY_SHOT_SERVER"] ?? ""
        guard let link = FlaccyServerLink(text: text) else { throw Failure(step: "FLACCY_SHOT_SERVER holds a flaccy://server link") }
        try await waitFor("the library lists MoveExercise") {
            Library.shared.allTracks.filter { LibraryPaths.relativePath(of: $0.fileURL).hasPrefix("MoveExercise/") }.count == 5
        }
        if let first = Library.shared.allTracks.first(where: { LibraryPaths.relativePath(of: $0.fileURL) == "MoveExercise/01 - First Light.m4a" }) {
            try DatabaseManager.shared.setLoved(fileURL: LibraryPaths.relativePath(of: first.fileURL), loved: true, pendingOp: nil)
        }
        step("loved before connecting: \(try DatabaseManager.shared.fetchLovedFileURLs().sorted())")
        let connection = try await FlaccyServerSetupGateway().connect(link: link, deviceName: "Mac Move Shot")
        guard await FlaccyServerSetupFollowUp().finish(connection), let record = FlaccyServerLibrary.record() else {
            throw Failure(step: "the server's music joined the library")
        }
        step("loved after connecting: \(try DatabaseManager.shared.fetchLovedFileURLs().sorted())")
        try await waitFor("the offer opens", timeout: 120) {
            if let merge = sheet(of: window) as? ServerMergeSummaryPanelViewController {
                DebugDrive.captureSheet(of: window, name: "flaccy-shot-server-move-merge")
                merge.dismiss(nil)
            }
            return sheet(of: window) is ServerMovePanelViewController
        }
        try await Task.sleep(for: .seconds(2))
        DebugDrive.captureSheet(of: window, name: "flaccy-shot-server-move-offer")
        sheet(of: window)?.dismiss(nil)
        try await Task.sleep(for: .seconds(1))

        host.presentAsSheet(FlaccyServerDetailPanelViewController(record: record))
        try await Task.sleep(for: .seconds(3))
        DebugDrive.captureSheet(of: window, name: "flaccy-shot-server-move-detail")
        sheet(of: window)?.dismiss(nil)
        try await Task.sleep(for: .seconds(1))

        host.presentAsSheet(ServerMovePanelViewController(serverID: record.id))
        try await waitFor("the offer is worked out again") {
            if case .offer = ServerMoveService.shared.phase(for: record.id) { true } else { false }
        }
        guard case .offer(let offer) = ServerMoveService.shared.phase(for: record.id) else { throw Failure(step: "an offer") }
        step("loved before moving: \(try DatabaseManager.shared.fetchLovedFileURLs().sorted()); offer loves \(offer.lovedSongs), pairs \(offer.pairs.map(\.local))")
        guard await ServerMoveService.shared.start(offer, choice: .stream(keepLoved: true)) != nil else {
            throw Failure(step: "the move finished (\(ServerMoveService.shared.phase(for: record.id)))")
        }
        try await Task.sleep(for: .seconds(2))
        DebugDrive.captureSheet(of: window, name: "flaccy-shot-server-move-done")
        sheet(of: window)?.dismiss(nil)
    }

    private static func step(_ text: String) {
        MidgarLog.info("Server move shot: \(text)", category: .general)
    }

    private static func sheet(of window: NSWindow) -> NSViewController? {
        window.attachedSheet?.contentViewController
    }

    private static func waitFor(_ what: String, timeout: TimeInterval = 60, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw Failure(step: what) }
            try await Task.sleep(for: .milliseconds(250))
        }
    }
}
#endif
