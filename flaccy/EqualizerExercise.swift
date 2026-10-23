import MidgarCore
#if DEBUG
import FlaccyCore
import Foundation

/// Plays two generated FLAC files through the real player with the equalizer
/// engaged and logs PASS/FAIL per expectation: the tap runs on FLAC at both
/// rates, a +9 dB bell lifts a 220 Hz tone by 9 dB, Compare removes it, the
/// gapless boundary shows no gap between render callbacks, and the equalizer
/// leaves no tap behind when it is switched off. Put `eqtest-a.flac` (44.1 kHz,
/// 16 bit, a 220 Hz tone) and `eqtest-b.flac` (96 kHz, 24 bit, a 1 kHz tone) in
/// the app's tmp/eqtest folder and launch with `--exercise-equalizer
/// --trial-day 2`; read the app log afterwards.
@MainActor
enum EqualizerExercise {

    static let launchArgument = "--exercise-equalizer"

    private static let boundaryGapLimitMilliseconds = 150.0
    private static let levelToleranceDecibels: Float = 1.5

    static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }
        Task { await run() }
    }

    private static func run() async {
        try? await Task.sleep(for: .seconds(3))
        let engine = EqualizerEngine.shared
        engine.start()

        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("eqtest", isDirectory: true)
        let fileA = folder.appendingPathComponent("eqtest-a.flac")
        let fileB = folder.appendingPathComponent("eqtest-b.flac")
        guard FileManager.default.fileExists(atPath: fileA.path), FileManager.default.fileExists(atPath: fileB.path) else {
            report("test files present in \(folder.path)", false)
            return
        }

        engine.setEnabled(false)
        engine.beginAnalysis(for: analysisOwner)
        AudioPlayer.shared.play([track(fileA, "Tone A"), track(fileB, "Tone B")], startingAt: 0)

        let tapRunning = await waitUntil(seconds: 10) { processingContext()?.framesProcessed ?? 0 > 0 }
        report("a tap is prepared and processing a 44.1 kHz 16-bit FLAC item with the equalizer off", tapRunning)
        guard tapRunning, let context = processingContext() else { return }
        report("tap format is \(Int(context.sampleRate)) Hz, \(context.channelCount) channels", context.sampleRate == 44_100 && context.channelCount == 2)

        try? await Task.sleep(for: .seconds(1))
        let dry = await settledPeak()
        report("dry 220 Hz tone reads \(format(dry)) dB (expected about -20)", abs(dry + 20) < 2.5)

        var previewProfile = EqualizerProfile.parametric(
            id: "audition-exercise",
            name: "Audition",
            bands: [EqualizerBand(type: .bell, frequency: 220, gain: 9, q: 1)]
        )
        previewProfile.isAutoPreamp = false
        previewProfile.manualPreamp = 0
        engine.beginAudition(previewProfile)
        let previewed = await settledPeak()
        report(
            "auditioning a +9 dB bell lifts the tone by \(format(previewed - dry)) dB while the saved state stays off",
            abs((previewed - dry) - 9) < levelToleranceDecibels && !engine.state.isEnabled && !engine.isRunning
        )
        engine.endAudition()
        let afterPreview = await settledPeak()
        report(
            "ending the audition returns the tone to \(format(afterPreview)) dB and the engine to passthrough",
            abs(afterPreview - dry) < levelToleranceDecibels && engine.auditioned == nil && !engine.isRunning
        )

        engine.edit { profile in
            profile.kind = .parametric
            profile.bands = [EqualizerBand(type: .bell, frequency: 220, gain: 9, q: 1)]
            profile.isAutoPreamp = false
            profile.manualPreamp = 0
        }
        engine.setEnabled(true)
        let wet = await settledPeak()
        report("a +9 dB bell at 220 Hz moved the tone by \(format(wet - dry)) dB", abs((wet - dry) - 9) < levelToleranceDecibels)

        engine.beginCompare()
        let compared = await settledPeak()
        report("Compare returns the tone to \(format(compared)) dB", abs(compared - dry) < levelToleranceDecibels)
        engine.endCompare()
        let restored = await settledPeak()
        report("releasing Compare brings the boost back to \(format(restored)) dB", abs(restored - wet) < levelToleranceDecibels)

        let autoProfileLevel = await autoPreampCheck(engine: engine, dry: dry)
        report("automatic preamp keeps the boosted tone at or below the dry level (\(format(autoProfileLevel)) dB)", autoProfileLevel <= dry + levelToleranceDecibels)

        let steadyGap = await largestGap(over: 3)
        report("steady playback: largest gap between render callbacks \(format(steadyGap)) ms", steadyGap < boundaryGapLimitMilliseconds)
        let boundary = await crossBoundary()
        report("gapless boundary: largest gap \(format(boundary.largestGap)) ms against \(format(steadyGap)) ms in steady playback", boundary.largestGap <= steadyGap + 40)
        report("the queue advanced to the 96 kHz 24-bit track", boundary.advanced)
        report("the next track's tap was built to start with the curve in force", boundary.nextTapStartsEngaged)
        if let second = processingContext() {
            report("tap re-prepared for the next item at \(Int(second.sampleRate)) Hz", second.sampleRate == 96_000)
        }

        engine.edit { profile in
            profile.kind = .parametric
            profile.bands = [EqualizerBand(type: .bell, frequency: 1_000, gain: 9, q: 1)]
            profile.isAutoPreamp = false
            profile.manualPreamp = 0
        }
        let wetB = await settledPeak()
        engine.beginCompare()
        let dryB = await settledPeak()
        engine.endCompare()
        report("at 96 kHz a +9 dB bell at 1 kHz moved the tone by \(format(wetB - dryB)) dB", abs((wetB - dryB) - 9) < levelToleranceDecibels)

        AudioPlayer.shared.seek(to: 1)
        let afterSeek = await waitUntil(seconds: 3) { (engine.millisecondsSinceLastRender ?? .infinity) < 100 }
        report("render callbacks continue after a seek", afterSeek)

        engine.setEnabled(false)
        engine.endAnalysis(for: analysisOwner)
        let detached = await waitUntil(seconds: 4) { engine.preparedTapCount == 0 }
        report("no tap is left attached once the equalizer is off (\(engine.preparedTapCount) prepared)", detached)

        engine.setEnabled(true)
        let reattached = await waitUntil(seconds: 4) { processingContext()?.framesProcessed ?? 0 > 0 && engine.preparedTapCount >= 1 }
        report("switching it back on attaches a tap while the song plays", reattached)

        AudioPlayer.shared.togglePlayPause()
        MidgarLog.info("EqualizerExercise finished", category: .playback)
    }

    private static let analysisOwner = NSObject()

    private static func autoPreampCheck(engine: EqualizerEngine, dry: Float) async -> Float {
        engine.edit { profile in
            profile.kind = .parametric
            profile.bands = [EqualizerBand(type: .bell, frequency: 220, gain: 9, q: 1)]
            profile.isAutoPreamp = true
        }
        return await settledPeak()
    }

    private static func crossBoundary() async -> (largestGap: Double, advanced: Bool, nextTapStartsEngaged: Bool) {
        EqualizerEngine.shared.edit { profile in
            profile.kind = .parametric
            profile.bands = [EqualizerBand(type: .bell, frequency: 220, gain: 9, q: 1)]
            profile.isAutoPreamp = false
            profile.manualPreamp = 0
        }
        AudioPlayer.shared.seek(to: max(AudioPlayer.shared.duration - 3, 0))
        try? await Task.sleep(for: .milliseconds(800))
        var largest = 0.0
        let deadline = Date().addingTimeInterval(7)
        while Date() < deadline {
            if let gap = EqualizerEngine.shared.millisecondsSinceLastRender {
                largest = max(largest, gap)
            }
            try? await Task.sleep(for: .milliseconds(4))
        }
        return (largest, AudioPlayer.shared.currentIndex == 1, processingContext()?.startsEngaged == true)
    }

    private static func largestGap(over seconds: Double) async -> Double {
        var largest = 0.0
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let gap = EqualizerEngine.shared.millisecondsSinceLastRender { largest = max(largest, gap) }
            try? await Task.sleep(for: .milliseconds(4))
        }
        return largest
    }

    private static func processingContext() -> EqualizerTapContext? {
        EqualizerTapRegistry.shared.playingContext()
    }

    private static func settledPeak() async -> Float {
        try? await Task.sleep(for: .seconds(1.2))
        var readings: [Float] = []
        for _ in 0..<5 {
            if let bins = EqualizerEngine.shared.spectrum(), let peak = bins.max() { readings.append(peak) }
            try? await Task.sleep(for: .milliseconds(120))
        }
        return readings.max() ?? -96
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
            artist: "Equalizer Exercise",
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

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func report(_ expectation: String, _ passed: Bool) {
        MidgarLog.info("EqualizerExercise \(passed ? "PASS" : "FAIL"): \(expectation)", category: .playback)
    }
}
#endif
