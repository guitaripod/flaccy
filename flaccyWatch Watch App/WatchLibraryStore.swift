import FlaccyCore
import Foundation
import Observation

@MainActor
@Observable
final class WatchLibraryStore {

    private(set) var albums: [MediaAlbum] = []
    private(set) var allTracks: [MediaItem] = []
    private(set) var isLoading: Bool = false

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

        let items = await LibraryScanner.scan(directory: documentsDirectory)
        guard gen == generation, !Task.isCancelled else { return }
        allTracks = items.sorted { lhs, rhs in
            lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        albums = LibraryScanner.albums(from: items)
        isLoading = false
        AppLogger.info("Watch library: \(albums.count) albums, \(items.count) tracks", category: .watch)
    }
}
