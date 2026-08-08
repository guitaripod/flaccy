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
        let items = await LibraryScanner.scan(directory: documentsDirectory) { [weak self] progress in
            guard tracker.update({ $0 = progress }) != nil else { return }
            let fraction = tracker.displayFraction
            Task { @MainActor [weak self] in
                self?.loadProgress = progress
                self?.loadFraction = fraction
            }
        }
        guard gen == generation, !Task.isCancelled else { return }
        allTracks = items.sorted { lhs, rhs in
            lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        albums = LibraryScanner.albums(from: items)
        isLoading = false
        loadProgress = .idle
        loadFraction = 0
        AppLogger.info("Watch library: \(albums.count) albums, \(items.count) tracks", category: .watch)
    }
}
