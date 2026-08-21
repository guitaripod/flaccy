import FlaccyCore
import Foundation
import Observation

@MainActor
@Observable
final class WatchLibraryStore {

    private(set) var albums: [MediaAlbum] = []
    private(set) var allTracks: [MediaItem] = []
    private(set) var isLoading: Bool = false
    private(set) var loadProgress: LibraryLoadProgress = .idle
    private(set) var loadFraction: Double = 0

    @ObservationIgnored let documentsDirectory: URL
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(documentsDirectory: URL) {
        self.documentsDirectory = documentsDirectory
    }

    var isEmpty: Bool { allTracks.isEmpty }

    func load() async {
        await performLoad(generation: nextGeneration())
    }

    /// Debounced, serialized rescan: sync delivers files back-to-back, so an
    /// N-track album collapses to one or two scans instead of N, and only the
    /// newest scan ever publishes — an older, smaller result can never
    /// overwrite a newer one.
    func reload() {
        let gen = nextGeneration()
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.performLoad(generation: gen)
        }
    }

    private func nextGeneration() -> Int {
        generation += 1
        return generation
    }

    private func performLoad(generation gen: Int) async {
        isLoading = true

        #if targetEnvironment(simulator)
        await SampleContent.seedIfNeeded(in: documentsDirectory)
        #endif

        let tracker = LibraryLoadProgressTracker()
        let relay = LoadProgressRelay(tracker: tracker)
        let delivery = Task { @MainActor [weak self] in
            for await snapshot in relay.snapshots {
                self?.apply(snapshot, generation: gen)
            }
        }

        relay.publish(LibraryLoadProgress(phase: .openingLibrary))
        let items = await LibraryScanner.scan(directory: documentsDirectory) { progress in
            relay.publish(progress)
        }
        relay.close()
        await delivery.value

        guard gen == generation, !Task.isCancelled else { return }
        allTracks = items.sorted { lhs, rhs in
            lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        albums = LibraryScanner.albums(from: items)
        isLoading = false
        loadFraction = tracker.displayFraction
        loadProgress = tracker.finish()
        AppLogger.info("Watch library: \(albums.count) albums, \(items.count) tracks", category: .watch)
    }

    private func apply(_ snapshot: LoadProgressRelay.Snapshot, generation gen: Int) {
        guard gen == generation else { return }
        loadProgress = snapshot.progress
        loadFraction = snapshot.fraction
    }
}

/// Carries scan progress to the main actor as whole snapshots, in order.
///
/// The scanner reports from whichever task finished a file first, so a detached
/// hop per update can land the phase and the fraction out of order — and a bar
/// that jitters backwards is at its most visible on the smallest screen there
/// is. Publishing under one lock makes "coalesce, read the fraction, enqueue"
/// a single step, and the stream preserves that order all the way to the one
/// assignment that moves both values together.
private final class LoadProgressRelay: @unchecked Sendable {

    struct Snapshot: Sendable {
        let progress: LibraryLoadProgress
        let fraction: Double
    }

    let snapshots: AsyncStream<Snapshot>

    private let tracker: LibraryLoadProgressTracker
    private let continuation: AsyncStream<Snapshot>.Continuation
    private let gate = NSLock()

    init(tracker: LibraryLoadProgressTracker) {
        self.tracker = tracker
        (snapshots, continuation) = AsyncStream.makeStream(of: Snapshot.self)
    }

    func publish(_ progress: LibraryLoadProgress) {
        gate.lock()
        defer { gate.unlock() }
        guard let published = tracker.update({ $0 = progress }) else { return }
        continuation.yield(Snapshot(progress: published, fraction: tracker.displayFraction))
    }

    func close() {
        continuation.finish()
    }
}
