import MidgarCore
#if DEBUG
import AVFoundation
import FlaccyCore
import FlaccyEngine
import Foundation
import UIKit

/// Proves what happens after another app takes the sound. Put a long `eqtest-a.flac` in the app's
/// tmp/eqtest folder (without it the queued song plays), launch with `--exercise-interruption`,
/// then bring an app that plays sound to the front within a minute. The exercise plays, waits to be
/// interrupted, waits two minutes to be played again by whichever path the person's choice allows,
/// pauses, and logs each step with its timing to the app log. A locked device never puts the app on
/// screen, which leaves only the background paths to prove; `--needs-screen` stops there instead.
@MainActor
enum InterruptionExercise {

    static let launchArgument = "--exercise-interruption"

    static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }
        Task { await run() }
    }

    private static func run() async {
        try? await Task.sleep(for: .seconds(3))
        guard let engine = (AudioPlayer.shared as? AudioPlayer)?.engine else { return }
        report("the choice is \(InterruptionResume.stored.rawValue)", true)
        let onScreen = UIApplication.shared.applicationState == .active
        report("the app is on screen", onScreen)
        if CommandLine.arguments.contains("--needs-screen"), !onScreen { return }
        let tone = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("eqtest/eqtest-a.flac")
        if FileManager.default.fileExists(atPath: tone.path) {
            AudioPlayer.shared.play([track(tone)], startingAt: 0)
        } else if engine.currentTrack != nil {
            if !engine.isPlaying { engine.togglePlayPause() }
        } else {
            report("a song is queued, or tmp/eqtest/eqtest-a.flac is there to play", false)
            return
        }
        let playing = await waitUntil(seconds: 10) { engine.isPlaying }
        report("music is playing", playing)
        guard playing else { return }

        let interrupted = await waitUntil(seconds: 60) { engine.isAwaitingInterruptionEnd }
        report("another app took the sound and the music paused", interrupted)
        guard interrupted else { return pause(engine) }

        let cutOff = Date()
        let resumed = await waitUntil(seconds: 120) { engine.isPlaying }
        let waited = String(format: "%.1f", Date().timeIntervalSince(cutOff))
        let other = AVAudioSession.sharedInstance().isOtherAudioPlaying
        report("the music played again after \(waited) s (other audio playing: \(other))", resumed)
        try? await Task.sleep(for: .seconds(3))
        report("the music is still playing three seconds on", engine.isPlaying == resumed)
        pause(engine)
    }

    private static func pause(_ engine: PlaybackEngine) {
        if engine.isPlaying { engine.togglePlayPause() }
        engine.abandonInterruptionWait()
    }

    private static func track(_ url: URL) -> Track {
        Track(
            fileURL: url,
            title: "Tone",
            artist: "Interruption Exercise",
            albumTitle: "Test Tones",
            albumArtist: nil,
            trackNumber: 1,
            duration: 300,
            artwork: nil,
            dbID: nil
        )
    }

    private static func waitUntil(seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    private static func report(_ expectation: String, _ passed: Bool) {
        MidgarLog.info("InterruptionExercise \(passed ? "PASS" : "FAIL"): \(expectation)", category: .playback)
    }
}
#endif
