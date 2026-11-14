import FlaccyCore
import Foundation
import MidgarCore

/// The Recap's `RecapLibraryIndex`, built off the main thread and kept until the
/// library changes. Building it normalizes every album and track key, which on a
/// library of thousands of songs holds a thread for long enough that building it
/// on the main thread for every Recap render froze the screen on first open.
final class RecapLibraryIndexCache {

    static let shared = RecapLibraryIndexCache()

    private var building: Task<RecapLibraryIndex, Never>?
    private var libraryObserver: NSObjectProtocol?

    private init() {
        libraryObserver = NotificationCenter.default.addObserver(
            forName: Library.didUpdateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.building = nil }
        }
    }

    /// Starts building the index for the library as it stands, so a render that
    /// asks for it moments later finds it ready or under way.
    func prepare() {
        _ = currentBuild()
    }

    /// The index for the library as it stands; built on first use after any
    /// change to the library, then shared by every caller until the next one.
    func index() async -> RecapLibraryIndex {
        await currentBuild().value
    }

    private func currentBuild() -> Task<RecapLibraryIndex, Never> {
        if let building { return building }
        let albums = Library.shared.albums
        let tracks = Library.shared.allTracks
        let build = Task.detached(priority: .userInitiated) {
            let started = DispatchTime.now().uptimeNanoseconds
            let index = RecapLibraryIndex(albums: albums, tracks: tracks)
            let milliseconds = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            MidgarLog.info(
                "Recap library index built in \(milliseconds) ms (\(albums.count) albums, \(tracks.count) tracks)",
                category: .performance
            )
            return index
        }
        building = build
        return build
    }
}
