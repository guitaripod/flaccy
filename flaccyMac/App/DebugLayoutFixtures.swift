import MidgarCore
#if DEBUG
import AppKit
import FlaccyCore

/// Fictional library content for checking the song pages' layouts: a two-disc
/// album, a compilation whose performers vary, a forty-song playlist and, on
/// request, an album of a thousand songs. Launched with
/// `--seed-layout-fixtures` next to `--seed-screenshots`; idempotent.
enum DebugLayoutFixtures {

    static let argument = "--seed-layout-fixtures"
    static let thousandArgument = "--seed-thousand"
    static let playlistName = "Road Trip"
    static let emptyPlaylistName = "Quiet"

    private struct Song {
        let path: String
        let title: String
        let artist: String
        let album: String
        let credit: String
        let number: Int
        let duration: Double
    }

    static func seedIfRequested() {
        guard CommandLine.arguments.contains(argument) else { return }
        let db = DatabaseManager.shared
        let known = (try? db.fetchAllTrackRelativePaths()) ?? []
        var songs: [Song] = []
        if !known.contains(where: { $0.hasPrefix("Orla Finch/Long Player/") }) {
            songs += longPlayer() + greatestHits() + [oneSong()]
        }
        if CommandLine.arguments.contains(thousandArgument),
           !known.contains(where: { $0.hasPrefix("Load Test/") }) {
            songs += thousandSongs()
        }
        write(songs, db: db)
        seedPlaylist(db: db)
    }

    private static let longPlayerTitles = [
        "Overture", "Glass Hours", "Salt Road", "Lantern", "Undertow", "Harbour Lights", "Paper Wings",
        "Slow Static", "Northbound", "Copper Sky", "Interlude", "Tidewater", "Afterglow", "Closing Credits",
    ]

    private static func longPlayer() -> [Song] {
        var songs: [Song] = []
        for (disc, suffix, count) in [(1, "(Part I)", 14), (2, "(Reprise)", 10)] {
            for index in 0..<count {
                let number = index + 1
                let title = "\(longPlayerTitles[index]) \(suffix)"
                songs.append(Song(
                    path: String(format: "Orla Finch/Long Player/CD%d/%02d - %@.wav", disc, number, title),
                    title: title, artist: "Orla Finch", album: "Long Player", credit: "Orla Finch",
                    number: number, duration: Double(150 + (index * 37 + disc * 11) % 140)
                ))
            }
        }
        return songs
    }

    private static func greatestHits() -> [Song] {
        let artists = ["Ada Lune", "Gale Knight", "Hollis Park", "Virelle", "Selkie", "Corvid & Crane", "Solveig"]
        return (1...20).map { number in
            let title = "Hit Number \(number)"
            return Song(
                path: String(format: "Various Artists/Greatest Hits Vol 1/%02d - %@.wav", number, title),
                title: title, artist: artists[(number * 3) % artists.count], album: "Greatest Hits Vol 1",
                credit: "Various Artists", number: number, duration: Double(170 + (number * 23) % 110)
            )
        }
    }

    private static func oneSong() -> Song {
        Song(
            path: "Orla Finch/One Song/01 - Alone.wav", title: "Alone", artist: "Orla Finch",
            album: "One Song", credit: "Orla Finch", number: 1, duration: 201
        )
    }

    private static func thousandSongs() -> [Song] {
        (1...1000).map { number in
            let title = "Song \(number)"
            return Song(
                path: String(format: "Load Test/Thousand Songs/%04d - %@.wav", number, title),
                title: title, artist: "Load Test", album: "Thousand Songs", credit: "Load Test",
                number: number, duration: 1
            )
        }
    }

    private static func write(_ songs: [Song], db: DatabaseManager) {
        guard !songs.isEmpty else { return }
        let fm = FileManager.default
        let now = Date()
        var albums: [String: Song] = [:]
        for (index, song) in songs.enumerated() {
            let url = LibraryPaths.root.appendingPathComponent(song.path)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let frequency = 196.0 * pow(2.0, Double(index % 12) / 12.0)
            try? ScreenshotSeeder.makeWAV(frequency: frequency, seconds: min(song.duration, 8)).write(to: url)
            albums[song.credit + "\u{0}" + song.album] = song
            let plays = index % 7 == 0 ? (index % 5) + 1 : 0
            let record = TrackRecord(
                fileURL: song.path, title: song.title, artist: song.artist, albumTitle: song.album,
                albumArtist: song.credit, trackNumber: song.number, duration: song.duration,
                artworkData: nil, lastFMArtworkURL: nil, musicBrainzID: nil, albumMusicBrainzID: nil,
                dateAdded: now, lastPlayed: plays > 0 ? now.addingTimeInterval(-3600) : nil, playCount: plays,
                aiAnalyzed: true, analysisAttemptedAt: now, codec: "FLAC", bitDepth: 16, sampleRate: 44100,
                channels: 2, loved: index % 9 == 3, lovedPendingOp: nil
            )
            _ = try? db.insertTrack(record)
        }
        for (key, song) in albums {
            let parts = key.split(separator: "\u{0}", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let demo = ScreenshotSeeder.DemoAlbum(
                artist: parts[0], title: parts[1], year: "2024", genre: "Fixture", bitDepth: 16, sampleRate: 44100,
                top: ScreenshotSeeder.rgb(0x1E5A4B), bottom: ScreenshotSeeder.rgb(0x0A1F1A),
                accent: ScreenshotSeeder.rgb(0x8FE3B8), motif: abs(song.album.hashValue) % 5, tracks: []
            )
            do {
                var info = try db.fetchOrCreateAlbumInfo(title: parts[1], artist: parts[0])
                info.coverArtData = CoverArtRenderer.render(demo)
                info.year = demo.year
                info.genre = demo.genre
                info.lastFetched = now
                try db.updateAlbumInfo(info)
            } catch {
                MidgarLog.error("Layout fixture album info failed: \(error.localizedDescription)", category: .database)
            }
        }
        MidgarLog.info("Layout fixtures seeded: \(songs.count) songs", category: .content)
    }

    private static func seedPlaylist(db: DatabaseManager) {
        if (try? db.fetchAllPlaylists().contains { $0.name == emptyPlaylistName }) == false {
            _ = try? db.createPlaylist(name: emptyPlaylistName)
        }
        guard (try? db.fetchAllPlaylists().contains { $0.name == playlistName }) == false,
              let paths = try? db.fetchAllTrackRelativePaths().sorted(),
              paths.count >= 40,
              let playlist = try? db.createPlaylist(name: playlistName),
              let id = playlist.id else { return }
        let hero = paths.first { $0.contains("Slow Machine") }
        let others = paths.filter { $0 != hero && !$0.hasPrefix("Load Test/") }
        let stride = max(others.count / 39, 1)
        var picked = (0..<39).map { others[($0 * stride) % others.count] }
        if let hero { picked.insert(hero, at: 11) } else { picked.append(others[0]) }
        for path in picked {
            try? db.addTrackToPlaylist(playlistId: id, trackFileURL: path)
        }
    }
}
#endif
