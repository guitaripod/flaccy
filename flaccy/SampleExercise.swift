#if DEBUG && os(iOS)
import Foundation

/// Runs the sample album through the real download on an empty library and
/// logs PASS/FAIL per expectation: playback starts before the last file lands,
/// and the queue ends holding the whole album exactly once. Launch with
/// `--exercise-sample` on a fresh simulator; read the app log afterwards.
@MainActor
enum SampleExercise {

    static let launchArgument = "--exercise-sample"

    static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }
        Task {
            try? await Task.sleep(for: .seconds(4))
            var playingBeforeDone = false
            let watcher = Task {
                while !Task.isCancelled {
                    if AudioPlayer.shared.currentTrack != nil, SampleMusicService.shared.isDownloading {
                        playingBeforeDone = true
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            let succeeded = await SampleMusicService.shared.downloadSamples()
            watcher.cancel()
            let queue = AudioPlayer.shared.queue.map(\.fileURL.lastPathComponent)
            let expected = ["goldberg-01-aria.flac", "goldberg-02-variatio1.flac", "goldberg-03-variatio4.flac"]
            report("download succeeded", succeeded)
            report("playback began before the download finished", playingBeforeDone)
            report("queue holds the whole album once (\(queue))", queue.count == expected.count && Set(queue) == Set(expected))
            report("progress text cleared", SampleMusicService.shared.progressText.isEmpty)
        }
    }

    private static func report(_ expectation: String, _ passed: Bool) {
        AppLogger.info("SampleExercise \(passed ? "PASS" : "FAIL"): \(expectation)", category: .content)
    }
}
#endif
