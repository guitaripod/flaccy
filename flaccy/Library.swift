import FlaccyCore
import Foundation

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

nonisolated struct LibraryImportOutcome: Sendable {
    let imported: Int
    let failed: Int
}

/// One album cover the scan has just moved out of a file and into the database,
/// announced while the tags are still being read.
///
/// It carries both spellings on purpose. `albumTitle`/`artist` are the raw tag
/// values the `albumInfo` row was written under, so an artwork lookup hits its
/// exact-match arm; `tileKey` is the identity the album model will eventually
/// have, so the mosaic dedupes this tile against the post-build pass.
nonisolated struct HoistedAlbumCover: Sendable, Hashable {
    let albumTitle: String
    let artist: String
    let tileKey: String
}

protocol LibraryProviding: AnyObject {
    var albums: [Album] { get }
    var allTracks: [Track] { get }
    var isLoading: Bool { get }
    var loadProgress: LibraryLoadProgress { get }
    var loadFraction: Double { get }
    func reload() async
    func resetAndReload() async
    func reloadFromDatabase() async
    func debutSummary() async -> LibraryDebutSummary
    @discardableResult
    func importFiles(from urls: [URL]) async -> LibraryImportOutcome
    func deleteTracks(_ tracks: [Track]) async
}

final class Library: LibraryProviding {

    static let shared: LibraryProviding = Library()
    static let didUpdateNotification = Notification.Name("LibraryDidUpdate")
    static let loadingStateChanged = Notification.Name("LibraryLoadingStateChanged")
    static let progressDidChange = Notification.Name("LibraryLoadProgressChanged")
    static let albumCoversHoisted = Notification.Name("LibraryAlbumCoversHoisted")

    enum ProgressKey {
        static let progress = "progress"
        static let fraction = "fraction"
    }

    enum CoverKey {
        static let covers = "covers"
    }

    private(set) var albums: [Album] = []
    private(set) var allTracks: [Track] = []
    private(set) var isLoading: Bool = false {
        didSet { NotificationCenter.default.post(name: Library.loadingStateChanged, object: nil) }
    }

    nonisolated private let progressTracker = LibraryLoadProgressTracker()

    nonisolated var loadProgress: LibraryLoadProgress { progressTracker.progress }
    nonisolated var loadFraction: Double { progressTracker.displayFraction }

    /// Publishes a coalesced progress snapshot; updates too small to see are
    /// dropped by the tracker rather than waking the main thread per file.
    nonisolated private func emitProgress(
        force: Bool = false, _ mutate: (inout LibraryLoadProgress) -> Void
    ) {
        guard let updated = progressTracker.update(force: force, mutate) else { return }
        NotificationCenter.default.post(
            name: Library.progressDidChange,
            object: nil,
            userInfo: [
                ProgressKey.progress: updated,
                ProgressKey.fraction: progressTracker.displayFraction,
            ]
        )
    }

    /// Ends the load on the fraction the tracker actually reached. Every phase
    /// left in the bar is bounded disk work, so a completed scan reports a real
    /// 1.0 and a scan that stopped short reports where it stopped, instead of
    /// the flat 1.0 the old network phases could never honestly claim.
    nonisolated private func finishProgress() {
        let reached = progressTracker.displayFraction
        let idle = progressTracker.finish()
        NotificationCenter.default.post(
            name: Library.progressDidChange,
            object: nil,
            userInfo: [ProgressKey.progress: idle, ProgressKey.fraction: reached]
        )
    }

    private let db = DatabaseManager.shared

    nonisolated private var documentsDirectory: URL {
        LibraryPaths.root
    }

    private var isReloading = false
    private var reloadPending = false

    func reload() async {
        if isReloading {
            reloadPending = true
            return
        }
        isReloading = true
        defer {
            isReloading = false
            finishProgress()
        }
        repeat {
            reloadPending = false
            await doReload()
        } while reloadPending
    }

    private func doReload() async {
        let firstLoad = albums.isEmpty
        if firstLoad {
            isLoading = true
            emitProgress(force: true) { $0 = LibraryLoadProgress(phase: .openingLibrary) }
            await restoreLastIndexedLibrary()
        }

        emitProgress(force: true) { $0.phase = .findingFiles }
        let syncChanged = await syncFilesWithDatabase()

        if firstLoad || syncChanged {
            emitProgress(force: true) { $0.phase = .buildingAlbums; $0.completed = 0; $0.total = 0 }
            await loadFromDatabase()
            publishLibraryTallies()
            AppLogger.info("Library: \(albums.count) albums, \(allTracks.count) tracks", category: .content)
        }

        NotificationCenter.default.post(name: Library.didUpdateNotification, object: nil)
        isLoading = false

        Task { await EnrichmentCoordinator.shared.resume() }
    }

    /// Shows whatever was indexed on a previous run before any disk work
    /// starts, so a relaunch lands on a usable library in milliseconds and the
    /// scan that follows is progress a person can watch rather than a wall.
    private func restoreLastIndexedLibrary() async {
        await loadFromDatabase()
        guard !albums.isEmpty else { return }
        publishLibraryTallies()
        NotificationCenter.default.post(name: Library.didUpdateNotification, object: nil)
    }

    /// Publishes the tallies, and closes `.buildingAlbums` out on a real total so
    /// a finished load reports 1.0 instead of the half credit an indeterminate
    /// phase is given — the bar used to stall at 92.5% and then vanish.
    ///
    /// The phase guard is load-bearing: `restoreLastIndexedLibrary()` calls this
    /// during `.openingLibrary`, and a completed count left behind there would
    /// make the file sweep that follows look determinate and already done.
    /// `max(albumCount, 1)` keeps an empty folder from staying indeterminate.
    private func publishLibraryTallies() {
        let albumCount = albums.count
        let trackCount = allTracks.count
        emitProgress(force: true) {
            $0.albumsBuilt = albumCount
            $0.tracksIndexed = max($0.tracksIndexed, trackCount)
            guard $0.phase == .buildingAlbums else { return }
            $0.total = max(albumCount, 1)
            $0.completed = $0.total
        }
    }

    /// Re-reads the album/track model from the database and republishes,
    /// unconditionally. Needed after a metadata-only mutation (album retitle,
    /// play-count transfer) that leaves files untouched, so `reload()`'s
    /// file-sync short-circuit would otherwise skip the refresh.
    func reloadFromDatabase() async {
        await loadFromDatabase()
        NotificationCenter.default.post(name: Library.didUpdateNotification, object: nil)
    }

    func resetAndReload() async {
        isLoading = true
        defer { finishProgress() }
        emitProgress(force: true) { $0 = LibraryLoadProgress(phase: .openingLibrary) }
        AppLogger.info("=== RESETTING LIBRARY ENRICHMENT STATE ===", category: .database)
        discardEnrichmentState()

        emitProgress(force: true) { $0.phase = .findingFiles }
        await syncFilesWithDatabase()
        emitProgress(force: true) { $0.phase = .buildingAlbums; $0.completed = 0; $0.total = 0 }
        await loadFromDatabase()
        publishLibraryTallies()
        logLibraryState()
        NotificationCenter.default.post(name: Library.didUpdateNotification, object: nil)
        isLoading = false
        forgetIndexedLibrary()

        Task { await EnrichmentCoordinator.shared.resume() }
    }

    /// Puts every durable enrichment verdict back to "never attempted": the AI
    /// flags, every `enrichmentState` row, and the once-per-library Debut. A
    /// reset that kept the negative cache would find nothing due and quietly do
    /// nothing at all.
    private func discardEnrichmentState() {
        do {
            try db.resetAllAIAnalyzed()
            try db.deleteAllEnrichmentState()
            try db.clearLibraryDebut()
        } catch {
            AppLogger.error("Failed to reset enrichment state: \(error.localizedDescription)", category: .database)
        }
    }

    /// Forgets that any earlier launch indexed this library, so the next launch
    /// earns the Debut again. Cleared last, because the rebuild this reset just
    /// ran marks the library indexed on its way through `loadFromDatabase()`.
    private func forgetIndexedLibrary() {
        LibraryStartupProbe.clear()
    }

    @discardableResult
    func importFiles(from urls: [URL]) async -> LibraryImportOutcome {
        var imported = 0
        var failed = 0
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let destination = uniqueDestination(for: url)
            do {
                try FileManager.default.copyItem(at: url, to: destination)
                imported += 1
                AppLogger.info("Imported: \(url.lastPathComponent)", category: .content)
            } catch {
                failed += 1
                AppLogger.error("Import failed: \(error.localizedDescription)", category: .content)
            }
        }
        await reload()
        return LibraryImportOutcome(imported: imported, failed: failed)
    }

    /// Deleting the files is the single source of truth — the reload's file
    /// sync then drops the database rows, playlist entries, and UI state.
    func deleteTracks(_ tracks: [Track]) async {
        guard !tracks.isEmpty else { return }
        for track in tracks {
            do {
                try FileManager.default.removeItem(at: track.fileURL)
                AppLogger.info("Deleted: \(track.fileURL.lastPathComponent)", category: .content)
            } catch {
                AppLogger.error("Delete failed for \(track.fileURL.lastPathComponent): \(error.localizedDescription)", category: .content)
            }
        }
        AudioPlayer.shared.handleDeletedTracks(Set(tracks.map(\.fileURL)))
        await reload()
    }

    @discardableResult
    @concurrent
    nonisolated private func syncFilesWithDatabase() async -> Bool {
        #if os(macOS)
        guard !LibraryRoot.shared.isFallbackActive else {
            AppLogger.warning(
                "Sync skipped: bookmarked library folder is unavailable; database left untouched",
                category: .content
            )
            return false
        }
        #endif
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: documentsDirectory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return false }

        let supportedExtensions: Set<String> = ["flac", "m4a", "aac", "alac", "mp3", "wav", "aiff", "aif", "caf"]
        var diskPaths = Set<String>()
        var diskFilesByPath = [String: URL]()

        for case let fileURL as URL in enumerator {
            guard supportedExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
            let relPath = relativePath(for: fileURL)
            diskPaths.insert(relPath)
            diskFilesByPath[relPath] = fileURL
            let found = diskPaths.count
            emitProgress { $0.filesFound = found }
        }
        let filesOnDisk = diskPaths.count
        emitProgress(force: true) { $0.filesFound = filesOnDisk }

        let knownPaths: Set<String>
        do {
            knownPaths = try db.fetchAllTrackRelativePaths()
        } catch {
            AppLogger.error("DB fetch paths error: \(error.localizedDescription)", category: .database)
            return false
        }

        let newPaths = diskPaths.subtracting(knownPaths)
        let removedPaths = knownPaths.subtracting(diskPaths)

        #if os(macOS)
        let rootChanged = recordCurrentRootIdentity()
        #endif

        if newPaths.isEmpty && removedPaths.isEmpty {
            AppLogger.info("Sync: \(diskPaths.count) files, no changes", category: .content)
            emitProgress(force: true) {
                $0.phase = .readingTags
                $0.completed = knownPaths.count
                $0.total = knownPaths.count
                $0.tracksIndexed = knownPaths.count
            }
            return false
        }

        if !removedPaths.isEmpty {
            #if os(macOS)
            guard !diskPaths.isEmpty || rootChanged else {
                AppLogger.warning(
                    "Sync: library root scanned empty while database holds \(knownPaths.count) tracks; skipping destructive cleanup",
                    category: .content
                )
                return false
            }
            if rootChanged {
                AppLogger.warning(
                    "Sync: library root changed; pruning \(removedPaths.count) rows indexed from the previous root",
                    category: .content
                )
            }
            #endif
            do {
                try db.deleteTracksNotIn(relativePaths: diskPaths)
            } catch {
                AppLogger.error("DB cleanup error: \(error.localizedDescription)", category: .database)
            }
        }

        let newCount = newPaths.count
        let alreadyIndexed = knownPaths.count - removedPaths.count
        emitProgress(force: true) {
            $0.phase = .readingTags
            $0.completed = 0
            $0.total = newCount
            $0.tracksIndexed = alreadyIndexed
        }

        await withTaskGroup(of: TrackRecord?.self) { group in
            for relPath in newPaths {
                guard let fileURL = diskFilesByPath[relPath] else { continue }
                group.addTask {
                    let metadata = await MetadataService.extractMetadata(from: fileURL)
                    return TrackRecord(
                        fileURL: relPath,
                        title: metadata.title,
                        artist: metadata.artist,
                        albumTitle: metadata.albumTitle,
                        trackNumber: metadata.trackNumber,
                        duration: metadata.duration,
                        artworkData: metadata.artwork?.jpegData(compressionQuality: 0.8),
                        lastFMArtworkURL: nil,
                        musicBrainzID: nil,
                        albumMusicBrainzID: nil,
                        dateAdded: Date(),
                        lastPlayed: nil,
                        playCount: 0,
                        aiAnalyzed: false,
                        analysisAttemptedAt: nil,
                        codec: metadata.codec,
                        bitDepth: metadata.bitDepth,
                        sampleRate: metadata.sampleRate,
                        channels: metadata.channels
                    )
                }
            }

            var buffer: [TrackRecord] = []
            var read = 0
            for await record in group {
                read += 1
                emitProgress {
                    $0.completed = read
                    $0.tracksIndexed = alreadyIndexed + read
                }
                guard let record else { continue }
                buffer.append(record)
                if buffer.count >= Self.insertBatchSize {
                    insertBatch(buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            insertBatch(buffer)
        }

        AppLogger.info("Sync: \(diskPaths.count) files on disk, \(newPaths.count) new, \(removedPaths.count) removed", category: .content)
        return true
    }

    private static let insertBatchSize = 50

    #if os(macOS)
    private static let rootIdentityKey = "flaccy.mac.libraryRootIdentity"

    /// Records which root the database rows were indexed from, returning true
    /// when the current root differs from the recorded one — the only case in
    /// which pruning rows against an empty scan is an intentional fresh start
    /// rather than a transient failure.
    nonisolated private func recordCurrentRootIdentity() -> Bool {
        let identity = documentsDirectory.standardizedFileURL.path
        let recorded = UserDefaults.standard.string(forKey: Self.rootIdentityKey)
        UserDefaults.standard.set(identity, forKey: Self.rootIdentityKey)
        return recorded != nil && recorded != identity
    }
    #endif

    nonisolated private func insertBatch(_ records: [TrackRecord]) {
        guard !records.isEmpty else { return }
        do {
            try db.insertTracks(records)
            announceHoistedCovers(in: records)
        } catch {
            AppLogger.error("Insert tracks error: \(error.localizedDescription)", category: .database)
        }
    }

    /// Announces the covers this batch just hoisted into `albumInfo`, so the
    /// Debut's mosaic can fill during `readingTags` rather than after it.
    ///
    /// The album model does not exist until the phase that follows the whole
    /// scan, so a reader watching Act I has nothing to look at unless the art is
    /// pushed from the insert that wrote it. Only sent once the write has
    /// committed, so every announced cover is already readable.
    nonisolated private func announceHoistedCovers(in records: [TrackRecord]) {
        var seen = Set<String>()
        var covers: [HoistedAlbumCover] = []
        for record in records where record.artworkData != nil && !record.albumTitle.isEmpty {
            let tileKey = "\(record.albumTitle)|\(LibraryHygiene.primaryArtist(record.artist))"
            guard seen.insert(tileKey).inserted else { continue }
            covers.append(HoistedAlbumCover(
                albumTitle: record.albumTitle, artist: record.artist, tileKey: tileKey
            ))
        }
        guard !covers.isEmpty else { return }
        NotificationCenter.default.post(
            name: Library.albumCoversHoisted, object: nil, userInfo: [CoverKey.covers: covers]
        )
    }

    private func loadFromDatabase() async {
        do {
            let loadedAlbums = try await fetchAlbumsFromDatabase()
            albums = loadedAlbums
            allTracks = loadedAlbums.flatMap(\.tracks)
            recordIndexedLibrary()
        } catch {
            AppLogger.error("Load from DB failed: \(error.localizedDescription)", category: .database)
        }
    }

    /// Records that this library has been built at least once, the moment the
    /// first read actually yields albums. The Debut has to decide whether to
    /// take the screen over before any `SELECT` could answer that, so the answer
    /// is written where the next launch can read it without opening anything.
    private func recordIndexedLibrary() {
        guard !albums.isEmpty, !LibraryStartupProbe.hadIndexedLibrary else { return }
        LibraryStartupProbe.markIndexed()
    }

    /// The figures the Debut's summary card reports, read from the database and
    /// the model the person just watched being built rather than from counters
    /// the scan kept — a scan that restarted must not make the card lie.
    func debutSummary() async -> LibraryDebutSummary {
        await Self.buildDebutSummary(albums: albums, tracks: allTracks)
    }

    @concurrent
    nonisolated private static func buildDebutSummary(
        albums: [Album], tracks: [Track]
    ) async -> LibraryDebutSummary {
        let db = DatabaseManager.shared
        var coversResolved = 0
        var albumsDated = 0
        for album in albums {
            guard let status = try? db.fetchAlbumInfoStatus(title: album.title, artist: album.artist) else { continue }
            if status.hasCover { coversResolved += 1 }
            if status.year != nil { albumsDated += 1 }
        }

        let aiCleanedTracks = ((try? db.fetchAllTracks()) ?? []).count { $0.aiAnalyzed }
        let bitrates = tracks.compactMap(bitrate(of:))

        return LibraryDebutSummary(
            trackCount: tracks.count,
            albumCount: albums.count,
            artistCount: Set(albums.map(\.artist)).count,
            coversResolved: coversResolved,
            albumsDated: albumsDated,
            aiCleanedTracks: aiCleanedTracks,
            losslessTrackCount: tracks.count(where: \.isLossless),
            averageBitrate: bitrates.isEmpty ? 0 : bitrates.reduce(0, +) / bitrates.count,
            totalDurationSeconds: tracks.reduce(0) { $0 + $1.duration },
            completedAt: Date()
        )
    }

    /// A track's uncompressed stream rate in kbps, which is what a lossless
    /// library's average is actually made of. Nil when the tags did not carry
    /// enough to say, so an unknown file lowers no average.
    nonisolated private static func bitrate(of track: Track) -> Int? {
        guard let sampleRate = track.sampleRate, let bitDepth = track.bitDepth else { return nil }
        let channels = track.channels ?? 2
        return sampleRate * bitDepth * channels / 1000
    }

    /// Builds the album list without decoded artwork: pinning full-tier
    /// bitmaps inside long-lived model structs would defeat
    /// `AlbumArtworkCache` eviction, and every reader already handles nil.
    @concurrent
    nonisolated private func fetchAlbumsFromDatabase() async throws -> [Album] {
        let albumsWithTracks = try db.fetchAlbumsWithTracksLightweight()

        var loadedAlbums: [Album] = []
        loadedAlbums.reserveCapacity(albumsWithTracks.count)

        for (albumInfo, trackRecords) in albumsWithTracks {
            let tracks = trackRecords.map { record in
                Track.from(light: record, artwork: nil)
            }
            guard !tracks.isEmpty else { continue }
            let title = Self.majorityValue(tracks.map(\.albumTitle))
            let artist = Self.majorityValue(tracks.map { LibraryHygiene.primaryArtist($0.artist) })
            loadedAlbums.append(Album(
                title: title,
                artist: artist,
                artwork: nil,
                tracks: tracks,
                year: albumInfo?.year,
                genre: albumInfo?.genre
            ))
        }

        if GroupAlbumEditionsSetting.isEnabled {
            loadedAlbums = LibraryHygiene.consolidateAlbums(loadedAlbums)
        }
        return loadedAlbums
    }

    private func logLibraryState() {
        AppLogger.info("Library: \(albums.count) albums, \(allTracks.count) tracks", category: .content)
    }

    nonisolated private static func majorityValue(_ values: [String]) -> String {
        var counts: [String: Int] = [:]
        for value in values {
            counts[value, default: 0] += 1
        }
        return counts.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key.count > rhs.key.count
        }?.key ?? values[0]
    }

    nonisolated private func relativePath(for url: URL) -> String {
        let docsPath = documentsDirectory.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        var relative = url.lastPathComponent
        if filePath.hasPrefix(docsPath) {
            relative = String(filePath.dropFirst(docsPath.count))
            if relative.hasPrefix("/") {
                relative = String(relative.dropFirst())
            }
        }
        #if os(macOS)
        return canonicalSyncPath(relative)
        #else
        return relative
        #endif
    }

    private func uniqueDestination(for sourceURL: URL) -> URL {
        let destination = documentsDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        let fm = FileManager.default
        guard fm.fileExists(atPath: destination.path) else { return destination }

        let name = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension
        var counter = 1
        var newDest = destination
        while fm.fileExists(atPath: newDest.path) {
            newDest = documentsDirectory.appendingPathComponent("\(name)_\(counter).\(ext)")
            counter += 1
        }
        return newDest
    }
}
