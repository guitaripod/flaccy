import Foundation
import MidgarCore
import Testing
@testable import flaccy

@MainActor
struct FunnelSignalsTests {
    /// Keeps the events it was handed. Reads and writes happen under one lock, which is what makes the unchecked conformance sound.
    private final class RecorderSpy: FunnelSignalRecording, @unchecked Sendable {
        struct Event: Equatable {
            let name: String
            let props: [String: MidgarSignalValue]
        }

        private let lock = NSLock()
        private var stored: [Event] = []

        var events: [Event] {
            lock.withLock { stored }
        }

        func record(_ name: String, props: [String: MidgarSignalValue]) {
            lock.withLock { stored.append(Event(name: name, props: props)) }
        }
    }

    private struct Harness {
        let signals: FunnelSignals
        let spy: RecorderSpy
        let defaults: UserDefaults
    }

    private func harness(suppressed: Bool = false) -> Harness {
        let suite = "flaccy.tests.funnel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let spy = RecorderSpy()
        let signals = FunnelSignals(
            recorder: spy,
            defaults: defaults,
            isSuppressed: { suppressed },
            libraryIsReadable: { true }
        )
        return Harness(signals: signals, spy: spy, defaults: defaults)
    }

    private func step(_ name: String) -> RecorderSpy.Event {
        RecorderSpy.Event(name: "funnel.step", props: ["step": .string(name)])
    }

    private func checkout(_ outcome: String, _ product: String) -> RecorderSpy.Event {
        RecorderSpy.Event(name: "paywall.checkout", props: ["outcome": .string(outcome), "product": .string(product)])
    }

    @Test func theSamplePlayingIsRecordedOnce() {
        let h = harness()
        h.signals.noteSamplePlayed()
        h.signals.noteSamplePlayed()
        #expect(h.spy.events == [step("sample_played")])
    }

    @Test func eachAddMusicOpeningIsRecorded() {
        let h = harness()
        h.signals.noteAddMusicOpened()
        h.signals.noteAddMusicOpened()
        #expect(h.spy.events == [step("add_music_opened"), step("add_music_opened")])
    }

    @Test func theLibraryFillingIsRecordedOnceWhenTheFirstOwnSongArrives() {
        let h = harness()
        h.signals.noteLibrary(ownTracks: 0)
        #expect(h.spy.events.isEmpty)
        h.signals.noteLibrary(ownTracks: 1)
        h.signals.noteLibrary(ownTracks: 40)
        #expect(h.spy.events == [step("library_filled")])
    }

    @Test func aLibraryThatFilledInAnEarlierLaunchIsNotRecordedAgain() {
        let h = harness()
        h.defaults.set(true, forKey: FunnelSignals.libraryFilledKey)
        h.signals.noteLibrary(ownTracks: 12)
        #expect(h.spy.events.isEmpty)
    }

    @Test func theTrialStartingIsRecorded() {
        let h = harness()
        h.signals.noteTrialStarted()
        #expect(h.spy.events == [step("trial_started")])
    }

    @Test func aFolderChosenOnTheMacCountsAsAnImport() {
        let h = harness()
        h.signals.noteFolderChosen()
        #expect(h.spy.events == [step("import_succeeded")])
    }

    @Test func anImportThatBroughtSongsInSucceedsEvenWithSomeSkippedOrFailed() {
        let h = harness()
        h.signals.noteImport(LibraryImportOutcome(imported: 10, skipped: 0, failed: 0))
        h.signals.noteImport(LibraryImportOutcome(imported: 3, skipped: 2, failed: 4))
        #expect(h.spy.events == [step("import_succeeded"), step("import_succeeded")])
    }

    @Test func anImportThatLostEverySongOrRanOutOfSpaceFails() {
        let h = harness()
        h.signals.noteImport(LibraryImportOutcome(imported: 0, skipped: 1, failed: 2))
        h.signals.noteImport(
            LibraryImportOutcome(imported: 0, skipped: 0, failed: 0, shortfall: StorageShortfall(needed: 10, available: 1))
        )
        #expect(h.spy.events == [step("import_failed"), step("import_failed")])
    }

    @Test func anImportThatFoundNothingNewRecordsNothing() {
        let h = harness()
        h.signals.noteImport(.empty)
        h.signals.noteImport(LibraryImportOutcome(imported: 0, skipped: 5, failed: 0))
        #expect(h.spy.events.isEmpty)
    }

    @Test func aCheckoutRecordsItsStartAndEachOutcomeWithTheProduct() {
        let h = harness()
        let product = "com.midgarcorp.flaccy.lifetime"
        h.signals.noteCheckoutStarted(product: product)
        h.signals.noteCheckoutFinished(.pending, product: product)
        h.signals.noteCheckoutFinished(.cancelled, product: product)
        h.signals.noteCheckoutFailed(product: product)
        #expect(h.spy.events == [
            checkout("started", product),
            checkout("pending", product),
            checkout("cancelled", product),
            checkout("failed", product),
        ])
    }

    @Test func aPurchaseIsLeftToTheStoresOwnSignal() {
        let h = harness()
        h.signals.noteCheckoutFinished(.purchased, product: "com.midgarcorp.flaccy.pro.yearly")
        #expect(h.spy.events.isEmpty)
    }

    @Test func theTrialDayOverrideSilencesEveryStepAndLeavesTheOnceFlagsUnset() {
        let h = harness(suppressed: true)
        h.signals.noteSamplePlayed()
        h.signals.noteLibrary(ownTracks: 5)
        h.signals.noteAddMusicOpened()
        h.signals.noteTrialStarted()
        h.signals.noteFolderChosen()
        h.signals.noteImport(LibraryImportOutcome(imported: 1, skipped: 0, failed: 0))
        h.signals.noteCheckoutStarted(product: "p")
        h.signals.noteCheckoutFinished(.cancelled, product: "p")
        h.signals.noteCheckoutFailed(product: "p")
        #expect(h.spy.events.isEmpty)
        #expect(!h.defaults.bool(forKey: FunnelSignals.libraryFilledKey))
        #expect(!h.defaults.bool(forKey: FunnelSignals.playedSampleKey))
    }
}
