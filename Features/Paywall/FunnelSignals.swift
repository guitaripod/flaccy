import Foundation
import MidgarCore
#if canImport(UIKit)
import UIKit
#endif

/// Where a funnel signal is handed over. Synchronous, so a call site stays one line and a test reads the result at once.
nonisolated protocol FunnelSignalRecording: Sendable {
    func record(_ signal: MidgarSignal)
}

/// Sends the event through the app's `MidgarSignals`, which applies the registry's uniqueness, and does nothing while signals are not configured (a test host, a screenshot seed).
nonisolated struct MidgarFunnelRecorder: FunnelSignalRecording {
    func record(_ signal: MidgarSignal) {
        Task { await MidgarSignals.shared?.send(signal) }
    }
}

/// Records each person's walk towards a purchase as anonymous counts: the first-run steps as `funnel.step`, which the
/// registry makes once per install, and the checkout of a plan as `paywall.checkout`. The trial lives in the Keychain and both paywalls are our own views, so
/// without this the signals only hear from the people who paid. `paywall.view` and `paywall.purchase` are recorded
/// elsewhere (`PurchaseManager.notePaywallShown`, `MidgarStore`), which is why a finished purchase is not repeated here.
///
/// The `--trial-day` clock is a fiction, so nothing it produces is recorded.
final class FunnelSignals {

    typealias Step = MidgarSignal.FunnelStep

    static let shared = FunnelSignals()

    static let libraryFilledKey = "flaccy.funnel.libraryFilled"
    static let playedSampleKey = "flaccy.funnel.playedSample"

    private let recorder: any FunnelSignalRecording
    private let defaults: UserDefaults
    private let isSuppressed: @MainActor () -> Bool
    private let libraryIsReadable: @MainActor () -> Bool
    private var libraryObserver: NSObjectProtocol?

    init(
        recorder: any FunnelSignalRecording = MidgarFunnelRecorder(),
        defaults: UserDefaults = .standard,
        isSuppressed: @escaping @MainActor () -> Bool = { PurchaseManager.shared.trialClockIsOverridden },
        libraryIsReadable: @escaping @MainActor () -> Bool = FunnelSignals.protectedDataIsAvailable
    ) {
        self.recorder = recorder
        self.defaults = defaults
        self.isSuppressed = isSuppressed
        self.libraryIsReadable = libraryIsReadable
    }

    /// Records, once, the first time the person's own library holds a song, whichever launch that is. Called as the
    /// library reloads.
    func observeLibrary() {
        guard libraryObserver == nil else { return }
        libraryObserver = NotificationCenter.default.addObserver(
            forName: Library.didUpdateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.libraryIsReadable() else { return }
                let sampleNames = SampleMusicService.sampleFileNames
                let own = Library.shared.allTracks.lazy
                    .filter { !SampleMusicService.isSample($0.fileURL, among: sampleNames) }
                    .count
                self.noteLibrary(ownTracks: own)
            }
        }
    }

    func noteLibrary(ownTracks: Int) {
        guard ownTracks > 0, !isSuppressed(), !defaults.bool(forKey: Self.libraryFilledKey) else { return }
        defaults.set(true, forKey: Self.libraryFilledKey)
        record(.libraryFilled)
    }

    func noteSamplePlayed() {
        guard !isSuppressed(), !defaults.bool(forKey: Self.playedSampleKey) else { return }
        defaults.set(true, forKey: Self.playedSampleKey)
        record(.samplePlayed)
    }

    func noteAddMusicOpened() {
        record(.addMusicOpened)
    }

    func noteTrialStarted() {
        record(.trialStarted)
    }

    /// The Mac can index a folder in place instead of copying, which is its way of getting music in.
    func noteFolderChosen() {
        record(.importSucceeded)
    }

    /// An import that brought in at least one song succeeded, whatever else it skipped or failed on. One that refused
    /// for space, or lost every song it tried, failed. Finding nothing or only songs already there is neither.
    func noteImport(_ outcome: LibraryImportOutcome) {
        guard let step = Self.step(for: outcome) else { return }
        record(step)
    }

    static func step(for outcome: LibraryImportOutcome) -> Step? {
        if outcome.shortfall != nil { return .importFailed }
        if outcome.imported > 0 { return .importSucceeded }
        if outcome.failed > 0 { return .importFailed }
        return nil
    }

    func noteCheckoutStarted(product: String) {
        recordCheckout(.started, product: product)
    }

    /// A purchase is left to `MidgarStore`'s `paywall.purchase`, which it records for every purchase made in the app.
    func noteCheckoutFinished(_ outcome: PurchaseManager.PurchaseOutcome, product: String) {
        switch outcome {
        case .purchased: return
        case .pending: recordCheckout(.pending, product: product)
        case .cancelled: recordCheckout(.cancelled, product: product)
        }
    }

    func noteCheckoutFailed(product: String) {
        recordCheckout(.failed, product: product)
    }

    private func record(_ step: Step) {
        guard !isSuppressed() else { return }
        MidgarLog.debug("Funnel step \(step.rawValue)", category: .purchases)
        recorder.record(.funnelStep(step: step))
    }

    private func recordCheckout(_ outcome: MidgarSignal.Outcome, product: String) {
        guard !isSuppressed() else { return }
        MidgarLog.debug("Funnel checkout \(outcome.rawValue) \(product)", category: .purchases)
        recorder.record(.paywallCheckout(outcome: outcome, product: product))
    }

    /// A launch before first unlock reads an empty library, because the database and the files are still protected;
    /// that is not the person having no music.
    static func protectedDataIsAvailable() -> Bool {
        #if canImport(UIKit)
        UIApplication.shared.isProtectedDataAvailable
        #else
        true
        #endif
    }
}
