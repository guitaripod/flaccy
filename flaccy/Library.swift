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
        isLoading = true
        await syncFilesWithDatabase()
        if hasUnanalyzedTracks() {
            await analyzeLibrary(dirtyOnly: true)
        }
        await loadFromDatabase()
        logLibraryState()
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

    private func syncFilesWithDatabase() async {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: documentsDirectory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return }

        var currentPaths = Set<String>()
        var newFiles: [URL] = []

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "flac" else { continue }
            let relPath = relativePath(for: fileURL)
            currentPaths.insert(relPath)

            do {
                if try db.fetchTrack(byRelativePath: relPath) == nil {
                    newFiles.append(fileURL)
                }
            } catch {
                AppLogger.error("DB fetch error: \(error.localizedDescription)", category: .database)
            }
        }

        do {
            try db.deleteTracksNotIn(relativePaths: currentPaths)
        } catch {
            AppLogger.error("DB cleanup error: \(error.localizedDescription)", category: .database)
        }

        for fileURL in newFiles {
            let metadata = await MetadataService.extractMetadata(from: fileURL)
            let record = TrackRecord(
                fileURL: relativePath(for: fileURL),
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
            do {
                try db.insertTrack(record)
            } catch {
                AppLogger.error("Insert track error: \(error.localizedDescription)", category: .database)
            }
        }

        AppLogger.info("Sync: \(currentPaths.count) files on disk, \(newFiles.count) new", category: .content)
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
            var loadedAlbums: [Album] = []

            for (albumInfo, trackRecords) in albumsWithTracks {
                let tracks = trackRecords.map { record in
                    let artwork: UIImage?
                    if let albumArtData = albumInfo?.coverArtData {
                        artwork = ImageCache.shared.imageFromData(albumArtData)
                    } else {
                        artwork = ImageCache.shared.imageFromData(record.artworkData)
                    }
                    return Track.from(record: record, artwork: artwork)
                }

                guard let first = tracks.first else { continue }
                let albumArtwork: UIImage?
                if let data = albumInfo?.coverArtData {
                    albumArtwork = ImageCache.shared.imageFromData(data)
                } else {
                    albumArtwork = tracks.first(where: { $0.artwork != nil })?.artwork
                }

                loadedAlbums.append(Album(
                    title: first.albumTitle,
                    artist: first.artist,
                    artwork: albumArtwork,
                    tracks: tracks,
                    year: albumInfo?.year,
                    genre: albumInfo?.genre
                ))
            }

            albums = loadedAlbums
            allTracks = loadedAlbums.flatMap(\.tracks)
        } catch {
            AppLogger.error("Load from DB failed: \(error.localizedDescription)", category: .database)
        }
    }

    private func logLibraryState() {
        AppLogger.info("=== LIBRARY: \(albums.count) albums, \(allTracks.count) tracks ===", category: .content)
        for album in albums {
            AppLogger.info("  [\(album.artist)] \(album.title) — \(album.tracks.count) tracks", category: .content)
            for track in album.tracks.prefix(3) {
                AppLogger.debug("    #\(track.trackNumber) \(track.title)", category: .content)
            }
            if album.tracks.count > 3 {
                AppLogger.debug("    ... +\(album.tracks.count - 3) more", category: .content)
            }
        }
    }

    private func enrichMissingMetadata() async {
        do {
            let albumsWithTracks = try db.fetchAlbumsWithTracks()
            var enrichedAny = false

            for (albumInfo, tracks) in albumsWithTracks {
                guard let first = tracks.first else { continue }
                if albumInfo?.coverArtData != nil { continue }

                AppLogger.info("Enriching: \(first.artist) — \(first.albumTitle)", category: .content)

                let result = await MetadataEnrichmentService.shared.enrichAlbum(
                    title: first.albumTitle, artist: first.artist
                )

                if result.coverArtData != nil || result.year != nil || result.genre != nil {
                    enrichedAny = true
                }

                do {
                    var info = try db.fetchOrCreateAlbumInfo(title: first.albumTitle, artist: first.artist)
                    info.coverArtURL = result.coverArtURL ?? info.coverArtURL
                    info.coverArtData = result.coverArtData ?? info.coverArtData
                    info.musicBrainzID = result.musicBrainzID ?? info.musicBrainzID
                    info.year = result.year ?? info.year
                    info.genre = result.genre ?? info.genre
                    info.lastFetched = Date()
                    try db.updateAlbumInfo(info)

                    if result.coverArtData != nil {
                        AppLogger.info("  Got cover art for \(first.albumTitle)", category: .content)
                    }

                    if let artistBio = result.artistBio {
                        var artist = try db.fetchOrCreateArtist(name: first.artist)
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
                AppLogger.info("UI refreshed with enriched metadata", category: .content)
            }
        } catch {
            AppLogger.error("Enrichment failed: \(error.localizedDescription)", category: .database)
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
            let tracks = try db.fetchAllTracks()
            return tracks.contains { !$0.aiAnalyzed }
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
