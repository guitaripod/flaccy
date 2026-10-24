import MidgarCore
#if DEBUG && targetEnvironment(simulator)
import FlaccyCore
import Foundation

/// Drives the receiver's delivery logic with synthesized files, because the
/// simulator pair does not carry WatchConnectivity file transfers. Logs PASS or
/// FAIL per expectation: a delivered file lands and is reported, a re-encode
/// replaces its original under another extension, a file of the wrong size or
/// on an unsafe path is refused, and removal by stem empties the folder.
/// Launch with `--exercise-receive`; read the app log afterwards.
nonisolated enum WatchReceiveExercise {

    static let launchArgument = "--exercise-receive"

    private static let folder = "Exercise Artist/Exercise Album"

    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains(launchArgument) else { return }
        Task.detached { run() }
    }

    private static func run() {
        let receiver = WatchSyncReceiver.shared
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("receive-exercise", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let lossless = "\(folder)/01 Song.flac"
        let encoded = "\(folder)/01 Song.m4a"

        deliver(receiver, staging: staging, path: lossless, bytes: 4_096, declared: 4_096)
        report("a delivered file is reported in the heartbeat", paths(receiver).contains(lossless))
        report("a delivered file is on disk", exists(lossless))

        deliver(receiver, staging: staging, path: encoded, bytes: 1_024, declared: 1_024)
        report("the re-encode is reported", paths(receiver).contains(encoded))
        report("the original under another extension is gone from the heartbeat", !paths(receiver).contains(lossless))
        report("the original under another extension is gone from disk", !exists(lossless) && exists(encoded))

        deliver(receiver, staging: staging, path: "\(folder)/02 Other.m4a", bytes: 2_048, declared: 9_999)
        report("a file of the wrong size is refused", !exists("\(folder)/02 Other.m4a"))
        report("the refusal is reported as a write failure", receiver.exerciseHeartbeat()[SyncKeys.lastErrorReason] as? String == StoreFailureReason.writeFailed.rawValue)

        deliver(receiver, staging: staging, path: "../Escape.m4a", bytes: 512, declared: 512)
        report("a path that climbs out of the library is refused", !FileManager.default.fileExists(atPath: documents.deletingLastPathComponent().appendingPathComponent("Escape.m4a").path))

        deliver(receiver, staging: staging, path: encoded, bytes: 2_000, declared: 2_000)
        report("a second delivery replaces the file in place", size(encoded) == 2_000 && paths(receiver).filter { $0 == encoded }.count == 1)
        report("a good delivery clears the error", receiver.exerciseHeartbeat()[SyncKeys.lastErrorReason] == nil)
        report("the heartbeat reports used and total bytes", (receiver.exerciseHeartbeat()[SyncKeys.usedBytes] as? Int64 ?? 0) >= 2_000 && (receiver.exerciseHeartbeat()[SyncKeys.totalBytes] as? Int64 ?? 0) > 0)

        receiver.exerciseCommand([SyncKeys.command: SyncKeys.commandRemove, SyncKeys.removePaths: ["\(folder)/01 Song"]])
        report("the phone removes a track by stem", !exists(encoded) && !paths(receiver).contains(encoded))
        try? FileManager.default.removeItem(at: documents.appendingPathComponent("Exercise Artist"))
        try? FileManager.default.removeItem(at: staging)
        MidgarLog.info("WatchReceiveExercise finished", category: .connectivity)
    }

    private static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static func deliver(_ receiver: WatchSyncReceiver, staging: URL, path: String, bytes: Int, declared: Int) {
        let source = staging.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: source.path, contents: Data(repeating: 7, count: bytes))
        let metadata = TransferMetadata(relativePath: path, title: "t", artist: "a", album: "b", trackNumber: 1, duration: 10, bytes: Int64(declared))
        receiver.exerciseStore(fileURL: source, metadata: metadata.dictionary)
    }

    private static func paths(_ receiver: WatchSyncReceiver) -> [String] {
        receiver.exerciseHeartbeat()[SyncKeys.syncedPaths] as? [String] ?? []
    }

    private static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: documents.appendingPathComponent(path).path)
    }

    private static func size(_ path: String) -> Int {
        (try? documents.appendingPathComponent(path).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private static func report(_ expectation: String, _ passed: Bool) {
        MidgarLog.info("WatchReceiveExercise \(passed ? "PASS" : "FAIL"): \(expectation)", category: .connectivity)
    }
}
#endif
