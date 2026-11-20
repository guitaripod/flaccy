import AVFoundation
import FlaccyCore
import FlaccyEngine
import MidgarCore
import UIKit

/// Listens, after another app took the sound, for that app to go quiet, and plays again when it does.
///
/// Most apps never hand the sound back: a video in a feed, a game or a voice message just stops, and
/// the system tells nobody. So while the person's choice is `whenQuiet` this samples whether another
/// app is playing, for as long as the system lets the app run in the background (about half a minute)
/// and whenever Flaccy is on screen. Coming back to Flaccy after that plays again at once.
@MainActor
final class InterruptionResumeWatcher {

    static let shared = InterruptionResumeWatcher()

    private var timer: Timer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var watch = InterruptionQuietWatch()
    private var activeObserver: NSObjectProtocol?
    private var lastSample: Bool?

    private weak var engine: PlaybackEngine?

    private var listens: Bool {
        InterruptionResume.stored.watchesForQuiet && engine?.isAwaitingInterruptionEnd == true
    }

    /// Starts noticing the app coming back on screen. Called once at launch.
    func start() {
        guard activeObserver == nil else { return }
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appBecameActive() }
        }
    }

    func interruptionBegan(in engine: PlaybackEngine) {
        self.engine = engine
        guard listens else { return }
        watch = InterruptionQuietWatch()
        lastSample = nil
        listen()
    }

    /// A choice that no longer listens drops the wait; the music stays paused.
    func choiceChanged() {
        guard !InterruptionResume.stored.watchesForQuiet else { return }
        stopListening()
    }

    /// Back in Flaccy the person is looking at the player, so a quiet phone is reason enough to play:
    /// the other app need not have been heard first.
    private func appBecameActive() {
        guard listens else { return }
        MidgarLog.info("Back on screen with an interruption pending", category: .playback)
        listen()
        sample()
    }

    private func listen() {
        holdBackgroundTime()
        guard timer == nil else { return }
        MidgarLog.info("Listening for the other app to go quiet", category: .playback)
        let timer = Timer(timeInterval: InterruptionQuietWatch.sampleInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func sample() {
        guard listens else {
            stopListening()
            return
        }
        let otherAudioPlaying = AVAudioSession.sharedInstance().isOtherAudioPlaying
        let onScreen = UIApplication.shared.applicationState == .active
        if otherAudioPlaying != lastSample {
            lastSample = otherAudioPlaying
            MidgarLog.debug("Other app playing: \(otherAudioPlaying), on screen: \(onScreen)", category: .playback)
        }
        guard watch.observe(otherAudioPlaying: otherAudioPlaying, playerIsOnScreen: onScreen) else { return }
        if engine?.resumeAfterInterruption() == true {
            MidgarLog.info("Resumed once the other app went quiet", category: .playback)
            stopListening()
        } else {
            watch.attemptWasRefused()
        }
    }

    private func holdBackgroundTime() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "InterruptionResume") { [weak self] in
            MainActor.assumeIsolated {
                MidgarLog.info("Background time ran out while listening for quiet", category: .playback)
                self?.stopListening()
            }
        }
    }

    private func stopListening() {
        timer?.invalidate()
        timer = nil
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
