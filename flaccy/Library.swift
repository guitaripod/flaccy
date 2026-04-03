import Foundation
import UIKit

protocol LibraryProviding: AnyObject {
    var albums: [Album] { get }
    var allTracks: [Track] { get }
    var isLoading: Bool { get }
    func reload() async
    func resetAndReload() async
    func importFiles(from urls: [URL]) async
}

final class Library: LibraryProviding {

    static let shared: LibraryProviding = Library()
    static let didUpdateNotification = Notification.Name("LibraryDidUpdate")
    static let loadingStateChanged = Notification.Name("LibraryLoadingStateChanged")

    private(set) var albums: [Album] = []
    private(set) var allTracks: [Track] = []
    private(set) var isLoading: Bool = false {
        didSet { NotificationCenter.default.post(name: Library.loadingStateChanged, object: nil) }
    }

    private let db = DatabaseManager.shared

    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL
    }

    func reload() async {
        let firstLoad = albums.isEmpty
        if firstLoad { isLoading = true }

        let syncChanged = await syncFilesWithDatabase()
        let needsAnalysis = hasUnanalyzedTracks()

        if needsAnalysis {
            isLoading = true
            await analyzeLibrary(dirtyOnly: true)
        }

        if firstLoad || syncChanged || needsAnalysis {
            await loadFromDatabase()
            AppLogger.info("Library: \(albums.count) albums, \(allTracks.count) tracks", category: .content)
        }

        NotificationCenter.default.post(name: Library.didUpdateNotification, object: nil)
        isLoading = false

        await enrichMissingMetadata()
    }

    func resetAndReload() async {
        isLoading = true
        AppLogger.info("=== RESETTING AI ANALYSIS FLAGS ===", category: .database)
        do {
            try db.resetAllAIAnalyzed()
        } catch {
            AppLogger.error("Failed to reset AI flags: \(error.localizedDescription)", category: .database)
        }

        await syncFilesWithDatabase()
        await analyzeLibrary(dirtyOnly: false)
        await loadFromDatabase()
        logLibraryState()
        NotificationCenter.default.post(name: Library.didUpdateNotification, object: nil)
        isLoading = false
        await enrichMissingMetadata()
    }

    func importFiles(from urls: [URL]) async {
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let destination = uniqueDestination(for: url)
            do {
                try FileManager.default.copyItem(at: url, to: destination)
                AppLogger.info("Imported: \(url.lastPathComponent)", category: .content)
            } catch {
                AppLogger.error("Import failed: \(error.localizedDescription)", category: .content)
            }
        }
        await reload()
    }

    @discardableResult
    private func syncFilesWithDatabase() async -> Bool {
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
        }

        let knownPaths: Set<String>
        do {
            knownPaths = try db.fetchAllTrackRelativePaths()
        } catch {
            AppLogger.error("DB fetch paths error: \(error.localizedDescription)", category: .database)
            return false
        }

        let newPaths = diskPaths.subtracting(knownPaths)
        let removedPaths = knownPaths.subtracting(diskPaths)

        if newPaths.isEmpty && removedPaths.isEmpty {
            AppLogger.info("Sync: \(diskPaths.count) files, no changes", category: .content)
            return false
        }

        if !removedPaths.isEmpty {
            do {
                try db.deleteTracksNotIn(relativePaths: diskPaths)
            } catch {
                AppLogger.error("DB cleanup error: \(error.localizedDescription)", category: .database)
            }
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
                        dateAdded: Date(),
                        playCount: 0,
                        aiAnalyzed: false
                    )
                }
            }

            for await record in group {
                guard let record else { continue }
                do {
                    try db.insertTrack(record)
                } catch {
                    AppLogger.error("Insert track error: \(error.localizedDescription)", category: .database)
                }
            }
        }

        AppLogger.info("Sync: \(diskPaths.count) files on disk, \(newPaths.count) new, \(removedPaths.count) removed", category: .content)
        return true
    }

    private func analyzeLibrary(dirtyOnly: Bool) async {
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

            var totalUpdated = 0
            for (dir, tracks) in grouped {
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
                            try db.updateTrack(dbTrack)
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
            let albumsWithTracks = try db.fetchAlbumsWithTracks()

            let loadedAlbums: [Album] = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    var result: [Album] = []
                    result.reserveCapacity(albumsWithTracks.count)

                    for (albumInfo, trackRecords) in albumsWithTracks {
                        let albumArt: UIImage? = {
                            if let data = albumInfo?.coverArtData { return UIImage(data: data) }
                            for record in trackRecords {
                                if let data = record.artworkData { return UIImage(data: data) }
                            }
                            return nil
                        }()

                        let tracks = trackRecords.map { record in
                            Track.from(record: record, artwork: albumArt)
                        }

                        guard let first = tracks.first else { continue }
                        result.append(Album(
                            title: first.albumTitle,
                            artist: first.artist,
                            artwork: albumArt,
                            tracks: tracks,
                            year: albumInfo?.year,
                            genre: albumInfo?.genre
                        ))
                    }
                    continuation.resume(returning: result)
                }
            }

            albums = loadedAlbums
            allTracks = loadedAlbums.flatMap(\.tracks)
        } catch {
            AppLogger.error("Load from DB failed: \(error.localizedDescription)", category: .database)
        }
    }

    private func logLibraryState() {
        AppLogger.info("Library: \(albums.count) albums, \(allTracks.count) tracks", category: .content)
    }

    private func enrichMissingMetadata() async {
        var enrichedAny = false

        for album in albums {
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

        if enrichedAny {
            await loadFromDatabase()
            NotificationCenter.default.post(name: Library.didUpdateNotification, object: nil)
        }
    }

    private func relativePath(for url: URL) -> String {
        let docsPath = documentsDirectory.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        if filePath.hasPrefix(docsPath) {
            let relative = String(filePath.dropFirst(docsPath.count))
            if relative.hasPrefix("/") {
                return String(relative.dropFirst())
            }
            return relative
        }
        return url.lastPathComponent
    }

    private func hasUnanalyzedTracks() -> Bool {
        do {
            return try db.hasUnanalyzedTracks()
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
