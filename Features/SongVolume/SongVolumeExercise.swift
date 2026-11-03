import MidgarCore
#if DEBUG
import FlaccyCore
import FlaccyEngine
import Foundation

/// Plays the equalizer exercise's two tone files through the real player and
/// proves each song's own volume follows its song: no tap at 0 dB with the
/// equalizer off, a tap that raises the playing song by 6 dB the moment the
/// level is set, the next song arriving gaplessly at its own -6 dB from its
/// first sample, and the tap gone again at 0 dB. Put `eqtest-a.flac` and
/// `eqtest-b.flac` in the app's tmp/eqtest folder, launch with
/// `--exercise-song-volume --trial-day 2` and read the app log afterwards.
/// Mirrors `FLACCY_DEMO_EQ=song-volume` on Linux.
@MainActor
enum SongVolumeExercise {

    static let launchArgument = "--exercise-song-volume"

    private static let levelToleranceDecibels: Float = 1.5
    private static let analysisOwner = NSObject()

    static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }
        Task { await run() }
    }

    private static func run() async {
        try? await Task.sleep(for: .seconds(3))
        let engine = EqualizerEngine.shared
        let store = SongVolumeStore.shared
        engine.start()
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("eqtest", isDirectory: true)
        let first = track(folder.appendingPathComponent("eqtest-a.flac"), "Tone A")
        let second = track(folder.appendingPathComponent("eqtest-b.flac"), "Tone B")
        guard FileManager.default.fileExists(atPath: first.fileURL.path), FileManager.default.fileExists(atPath: second.fileURL.path) else {
            report("test files present in \(folder.path)", false)
            return
        }
        engine.setEnabled(false)
        _ = try? store.set(0, for: first)
        _ = try? store.set(0, for: second)

        engine.beginAnalysis(for: analysisOwner)
        AudioPlayer.shared.play([first, second], startingAt: 0)
        let running = await waitUntil(seconds: 10) { (EqualizerTapRegistry.shared.playingContext()?.framesProcessed ?? 0) > 0 }
        report("the first song is playing through a tap", running)
        guard running else { return finish() }
        let dry = await settledLevel()
        report("the first song at 0 dB reads \(format(dry)) dB", abs(dry + 20) < 0.5)

        engine.endAnalysis(for: analysisOwner)
        let untouched = await waitUntil(seconds: 4) { engine.preparedTapCount == 0 }
        report("at 0 dB with the equalizer off no tap is attached (\(engine.preparedTapCount) prepared)", untouched)

        let stored = (try? store.set(60, for: first)) ?? 0
        let attached = await waitUntil(seconds: 4) { (EqualizerTapRegistry.shared.playingContext()?.framesProcessed ?? 0) > 0 }
        let raised = await settledLevel()
        report(
            "raising the playing song to +6 dB attaches a tap and lifts it by \(format(raised - dry)) dB",
            stored == 60 && attached && abs((raised - dry) - 6) < levelToleranceDecibels
        )
        report("the level is stored for the song", store.level(for: first) == 60 && (try? DatabaseManager.shared.songGain(title: first.title, artist: first.artist)) == 60)

        _ = try? store.set(-60, for: second)
        let unchanged = await settledLevel()
        report(
            "setting the next song's level leaves the playing one \(format(unchanged - dry)) dB up",
            abs((unchanged - dry) - 6) < levelToleranceDecibels
        )

        AudioPlayer.shared.seek(to: max(AudioPlayer.shared.duration - 3, 0))
        let advanced = await waitUntil(seconds: 8) { AudioPlayer.shared.currentIndex == 1 }
        report("the queue advanced to the second song", advanced)
        let nextContext = EqualizerTapRegistry.shared.playingContext()
        report("the second song's tap was built to start at its own level", nextContext?.startsEngaged == true && nextContext?.songGain.read() == -60)
        let after = await settledLevel()
        report(
            "the second song plays at its own -6 dB: \(format(after)) dB against \(format(dry)) dB dry",
            abs((after - dry) + 6) < levelToleranceDecibels
        )

        _ = try? store.set(0, for: second)
        let detached = await waitUntil(seconds: 4) { engine.preparedTapCount == 0 }
        report("back at 0 dB the tap is gone again (\(engine.preparedTapCount) prepared)", detached)

        _ = try? store.set(0, for: first)
        finish()
    }

    private static func finish() {
        if AudioPlayer.shared.isPlaying { AudioPlayer.shared.togglePlayPause() }
        MidgarLog.info("SONG VOLUME EXERCISE FINISHED", category: .playback)
    }

    /// The sample peak the playing tap let through over the last moments, in dBFS.
    private static func settledLevel() async -> Float {
        try? await Task.sleep(for: .seconds(1.2))
        var loudest: Float = 0
        for _ in 0..<5 {
            if let meter = EqualizerEngine.shared.meter() { loudest = max(loudest, meter.peak) }
            try? await Task.sleep(for: .milliseconds(120))
        }
        return 20 * log10(max(loudest, 1e-6))
    }

    private static func waitUntil(seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private static func track(_ url: URL, _ title: String) -> Track {
        Track(
            fileURL: url,
            title: title,
            artist: "Song Volume Exercise",
            albumTitle: "Test Tones",
            albumArtist: nil,
            trackNumber: 1,
            duration: 40,
            artwork: nil,
            dbID: nil
        )
    }

    private static func format(_ value: Float) -> String {
        String(format: "%.1f", value)
    }

    private static func report(_ expectation: String, _ passed: Bool) {
        MidgarLog.info("SongVolumeExercise \(passed ? "PASS" : "FAIL"): \(expectation)", category: .playback)
    }
}
#endif
