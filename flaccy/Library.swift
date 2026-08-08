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

protocol LibraryProviding: AnyObject {
    var albums: [Album] { get }
    var allTracks: [Track] { get }
    var isLoading: Bool { get }
    var loadProgress: LibraryLoadProgress { get }
    var loadFraction: Double { get }
    func reload() async
    func resetAndReload() async
    func reloadFromDatabase() async
    @discardableResult
    func importFiles(from urls: [URL]) async -> LibraryImportOutcome
    func deleteTracks(_ tracks: [Track]) async
}

final class Library: LibraryProviding {

    static let shared: LibraryProviding = Library()
    static let didUpdateNotification = Notification.Name("LibraryDidUpdate")
    static let loadingStateChanged = Notification.Name("LibraryLoadingStateChanged")
    static let progressDidChange = Notification.Name("LibraryLoadProgressChanged")

    enum ProgressKey {
        static let progress = "progress"
        static let fraction = "fraction"
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

    nonisolated private func finishProgress() {
        let idle = progressTracker.finish()
        NotificationCenter.default.post(
            name: Library.progressDidChange,
            object: nil,
            userInfo: [ProgressKey.progress: idle, ProgressKey.fraction: 1.0]
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
        let needsAnalysis = hasUnanalyzedTracks()

        if needsAnalysis {
            isLoading = true
            await analyzeLibrary(dirtyOnly: true)
        }

        if firstLoad || syncChanged || needsAnalysis {
            emitProgress(force: true) { $0.phase = .buildingAlbums; $0.completed = 0; $0.total = 0 }
            await loadFromDatabase()
            publishLibraryTallies()
            AppLogger.info("Library: \(albums.count) albums, \(allTracks.count) tracks", category: .content)
        }

        NotificationCenter.default.post(name: Library.didUpdateNotification, object: nil)
        isLoading = false

        await enrichAndPublish()
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

    private func publishLibraryTallies() {
        let albumCount = albums.count
        let trackCount = allTracks.count
        emitProgress(force: true) {
            $0.albumsBuilt = albumCount
            $0.tracksIndexed = max($0.tracksIndexed, trackCount)
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

    private func enrichAndPublish() async {
        guard await enrichMissingMetadata(for: albums) else { return }
        await loadFromDatabase()
        NotificationCenter.default.post(name: Library.didUpdateNotification, object: nil)
    }

    func resetAndReload() async {
        isLoading = true
        defer { finishProgress() }
        emitProgress(force: true) { $0 = LibraryLoadProgress(phase: .openingLibrary) }
        AppLogger.info("=== RESETTING AI ANALYSIS FLAGS ===", category: .database)
        do {
            try db.resetAllAIAnalyzed()
        } catch {
            AppLogger.error("Failed to reset AI flags: \(error.localizedDescription)", category: .database)
        }

        emitProgress(force: true) { $0.phase = .findingFiles }
        await syncFilesWithDatabase()
        await analyzeLibrary(dirtyOnly: false)
        emitProgress(force: true) { $0.phase = .buildingAlbums; $0.completed = 0; $0.total = 0 }
        await loadFromDatabase()
        publishLibraryTallies()
        logLibraryState()
        NotificationCenter.default.post(name: Library.didUpdateNotification, object: nil)
        isLoading = false
        await enrichAndPublish()
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
        } catch {
            AppLogger.error("Insert tracks error: \(error.localizedDescription)", category: .database)
        }
    }

    @concurrent
    nonisolated private func analyzeLibrary(dirtyOnly: Bool) async {
        do {
            let allDBTracks = try db.fetchAllTracks()
            guard !allDBTracks.isEmpty else { return }

            let tracksToAnalyze: [TrackRecord]
            if dirtyOnly {
                tracksToAnalyze = allDBTracks.filter { !$0.aiAnalyzed }
                guard !tracksToAnalyze.isEmpty else {
                    AppLogger.info("No tracks need AI analysis", category: .content)
                    return
                }
            } else {
                tracksToAnalyze = allDBTracks
            }

            let grouped = Dictionary(grouping: tracksToAnalyze) { track -> String in
                let components = track.fileURL.split(separator: "/")
                return components.count > 1 ? String(components.dropLast().joined(separator: "/")) : ""
            }

            AppLogger.info("Analyzing \(tracksToAnalyze.count) tracks in \(grouped.count) batches", category: .content)
            let batchCount = grouped.count
            emitProgress(force: true) {
                $0.phase = .identifyingMusic
                $0.completed = 0
                $0.total = batchCount
            }

            var totalUpdated = 0
            var batchesDone = 0
            for (dir, tracks) in grouped {
                defer {
                    batchesDone += 1
                    let done = batchesDone
                    emitProgress(force: true) { $0.completed = done }
                }
                let contexts = tracks.map { track in
                    TrackContext(
                        relativePath: track.fileURL,
                        currentTitle: track.title,
                        currentArtist: track.artist,
                        currentAlbum: track.albumTitle,
                        trackNumber: track.trackNumber
                    )
                }

                AppLogger.info("Batch: \(dir) (\(tracks.count) tracks)", category: .content)
                try? db.markAnalysisAttempted(fileURLs: tracks.map(\.fileURL))

                guard let identified = await GroqService.shared.analyzeLibrary(tracks: contexts) else {
                    AppLogger.warning("Groq returned no results for batch: \(dir)", category: .content)
                    continue
                }

                for identifiedAlbum in identified.albums {
                    AppLogger.info("  Identified: \(identifiedAlbum.artist) — \(identifiedAlbum.album)", category: .content)

                    for identifiedTrack in identifiedAlbum.tracks {
                        guard var dbTrack = tracks.first(where: { track in
                            let filename = URL(fileURLWithPath: track.fileURL).lastPathComponent
                            return filename.lowercased() == identifiedTrack.filename.lowercased()
                                || track.fileURL.lowercased().hasSuffix(identifiedTrack.filename.lowercased())
                        }) else { continue }

                        dbTrack.artist = identifiedAlbum.artist
                        dbTrack.albumTitle = identifiedAlbum.album
                        dbTrack.title = identifiedTrack.title
                        dbTrack.trackNumber = identifiedTrack.trackNumber
                        dbTrack.aiAnalyzed = true

                        do {
                            try db.updateTrackPreservingArtwork(dbTrack)
                            totalUpdated += 1
                        } catch {
                            AppLogger.error("Track update failed: \(error.localizedDescription)", category: .database)
                        }
                    }

                    do {
                        var albumInfo = try db.fetchOrCreateAlbumInfo(
                            title: identifiedAlbum.album, artist: identifiedAlbum.artist
                        )
                        if let year = identifiedAlbum.year { albumInfo.year = year }
                        if let genre = identifiedAlbum.genre { albumInfo.genre = genre }
                        albumInfo.lastFetched = nil
                        try db.updateAlbumInfo(albumInfo)
                    } catch {
                        AppLogger.error("Album info save failed: \(error.localizedDescription)", category: .database)
                    }
                }
            }

            AppLogger.info("AI analysis done: \(totalUpdated)/\(tracksToAnalyze.count) tracks updated", category: .content)
        } catch {
            AppLogger.error("Library analysis failed: \(error.localizedDescription)", category: .database)
        }
    }

    private func loadFromDatabase() async {
        do {
            let loadedAlbums = try await fetchAlbumsFromDatabase()
            albums = loadedAlbums
            allTracks = loadedAlbums.flatMap(\.tracks)
        } catch {
            AppLogger.error("Load from DB failed: \(error.localizedDescription)", category: .database)
        }
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

    @concurrent
    nonisolated private func enrichMissingMetadata(for albums: [Album]) async -> Bool {
        var enrichedAny = false
        let albumCount = albums.count
        emitProgress(force: true) {
            $0.phase = .enrichingArtwork
            $0.completed = 0
            $0.total = albumCount
            $0.albumsBuilt = albumCount
        }

        for (index, album) in albums.enumerated() {
            emitProgress { $0.completed = index }
            let albumInfo = try? db.fetchAlbumInfo(title: album.title, artist: album.artist)
            if albumInfo?.coverArtData != nil { continue }
            if let lastFetched = albumInfo?.lastFetched,
               Date().timeIntervalSince(lastFetched) < 24 * 3600 {
                continue
            }

            AppLogger.info("Enriching: \(album.artist) — \(album.title)", category: .content)

            let result = await MetadataEnrichmentService.shared.enrichAlbum(
                title: album.title, artist: album.artist
            )

            if result.coverArtData != nil || result.year != nil || result.genre != nil {
                enrichedAny = true
            }

            do {
                var info = try db.fetchOrCreateAlbumInfo(title: album.title, artist: album.artist)
                info.coverArtURL = result.coverArtURL ?? info.coverArtURL
                info.coverArtData = result.coverArtData ?? info.coverArtData
                info.musicBrainzID = result.musicBrainzID ?? info.musicBrainzID
                info.year = result.year ?? info.year
                info.genre = result.genre ?? info.genre
                info.lastFetched = Date()
                try db.updateAlbumInfo(info)

                if let artistBio = result.artistBio {
                    var artist = try db.fetchOrCreateArtist(name: album.artist)
                    artist.bio = artistBio
                    artist.imageURL = result.artistImageURL ?? artist.imageURL
                    artist.musicBrainzID = result.artistMusicBrainzID ?? artist.musicBrainzID
                    artist.lastFetched = Date()
                    try db.updateArtist(artist)
                }
            } catch {
                AppLogger.error("Enrichment save failed: \(error.localizedDescription)", category: .database)
            }
        }

        return enrichedAny
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

    private static let analysisRetryInterval: TimeInterval = 24 * 60 * 60

    private func hasUnanalyzedTracks() -> Bool {
        do {
            return try db.hasUnanalyzedTracks(attemptedBefore: Date().addingTimeInterval(-Self.analysisRetryInterval))
        } catch { return false }
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
