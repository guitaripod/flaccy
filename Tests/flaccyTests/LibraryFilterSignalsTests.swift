import XCTest
import Foundation
import FlaccyCore
@testable import flaccy

/// The pivot chips read one in-memory pass over the warmed track metadata, and
/// they must rank exactly as the shared rules and the Linux client do.
nonisolated final class LibraryFilterSignalsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func track(_ title: String, album: String, artist: String = "Aurelia Vance") -> Track {
        Track(
            fileURL: LibraryPaths.root.appendingPathComponent("\(artist)/\(album)/\(title).flac", isDirectory: false),
            title: title, artist: artist, albumTitle: album, albumArtist: nil,
            trackNumber: 1, duration: 200, artwork: nil, dbID: 1,
            codec: "FLAC", bitDepth: 16, sampleRate: 44_100, channels: 2
        )
    }

    private func meta(_ track: Track, added: Date, played: Date?, plays: Int) -> (String, LibraryViewModel.TrackMeta) {
        let key = LibraryPaths.relativePath(of: track.fileURL)
        var populated = track
        populated.playCount = plays
        return (key, LibraryViewModel.TrackMeta(track: populated, dateAdded: added, lastPlayed: played))
    }

    private func daysAgo(_ days: Double) -> Date {
        now.addingTimeInterval(-days * 86_400 - 3_600)
    }

    private func album(_ title: String, tracks: [Track]) -> Album {
        Album(title: title, artist: "Aurelia Vance", artwork: nil, tracks: tracks, year: nil, genre: nil)
    }

    func testRediscoverSumsAnAlbumsPlaysAndTakesItsNewestPlay() {
        let neglected = [track("one", album: "Neglected"), track("two", album: "Neglected")]
        let barely = [track("three", album: "Barely")]
        let recent = [track("four", album: "Recent")]
        let unheard = [track("five", album: "Unheard")]

        var meta = [String: LibraryViewModel.TrackMeta]()
        meta.merge([
            self.meta(neglected[0], added: daysAgo(400), played: daysAgo(60), plays: 4),
            self.meta(neglected[1], added: daysAgo(300), played: daysAgo(20), plays: 3),
            self.meta(barely[0], added: daysAgo(400), played: daysAgo(30), plays: 2),
            self.meta(recent[0], added: daysAgo(400), played: daysAgo(1), plays: 9),
            self.meta(unheard[0], added: daysAgo(400), played: nil, plays: 9),
        ]) { first, _ in first }

        let signals = LibraryViewModel.buildFilterSignals(
            albums: [
                album("Neglected", tracks: neglected), album("Barely", tracks: barely),
                album("Recent", tracks: recent), album("Unheard", tracks: unheard),
            ],
            meta: meta,
            now: now
        )

        XCTAssertEqual(signals.rediscover.albums.map(\.title), ["Neglected", "Barely"])
        XCTAssertEqual(signals.rediscover.keys, ["Neglected|Aurelia Vance", "Barely|Aurelia Vance"])
        XCTAssertEqual(signals.played["Neglected|Aurelia Vance"], daysAgo(20))
        XCTAssertEqual(signals.added["Neglected|Aurelia Vance"], daysAgo(300))
        XCTAssertNil(signals.played["Unheard|Aurelia Vance"])
    }

    func testRediscoverRankingIsTheSharedRulesRanking() {
        let titles = ["A", "B", "C", "D"]
        var albums: [Album] = []
        var meta = [String: LibraryViewModel.TrackMeta]()
        var entries: [(id: String, plays: Int, lastPlayed: Date?)] = []
        for (index, title) in titles.enumerated() {
            let songs = [track("s", album: title)]
            albums.append(album(title, tracks: songs))
            let played = daysAgo(Double(20 + index * 15))
            let plays = 2 + index
            meta.merge([self.meta(songs[0], added: daysAgo(500), played: played, plays: plays)]) { first, _ in first }
            entries.append((id: "\(title)|Aurelia Vance", plays: plays, lastPlayed: played))
        }

        let signals = LibraryViewModel.buildFilterSignals(albums: albums, meta: meta, now: now)
        XCTAssertEqual(
            signals.rediscover.albums.map(\.title),
            LibraryFilterRules.rediscover(entries, now: now).map { $0.components(separatedBy: "|")[0] }
        )
    }

    func testRecentlyAddedUsesTheAlbumThresholdsAndFallsBackToTheNewest() {
        let quiet = (1...3).map { index in
            album("Album \(index)", tracks: [track("s", album: "Album \(index)")])
        }
        var meta = [String: LibraryViewModel.TrackMeta]()
        meta.merge([self.meta(quiet[0].tracks[0], added: daysAgo(1), played: nil, plays: 0)]) { first, _ in first }
        meta.merge([self.meta(quiet[1].tracks[0], added: daysAgo(2), played: nil, plays: 0)]) { first, _ in first }
        meta.merge([self.meta(quiet[2].tracks[0], added: daysAgo(90), played: nil, plays: 0)]) { first, _ in first }

        let signals = LibraryViewModel.buildFilterSignals(albums: quiet, meta: meta, now: now)
        let added = quiet.map { (id: LibraryViewModel.albumFilterKey($0), dateAdded: signals.added[LibraryViewModel.albumFilterKey($0)] ?? .distantPast) }
        let ids = LibraryFilterRules.recentlyAdded(added, now: now, thresholds: .albums)

        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(ids.first, "Album 1|Aurelia Vance")
        XCTAssertEqual(ids.last, "Album 3|Aurelia Vance")
    }

    func testRelativePathNeedsNoFileSystemLookup() {
        let root = LibraryPaths.rootPath
        let url = LibraryPaths.root.appendingPathComponent("Artist/Album/01 Song.flac", isDirectory: false)

        XCTAssertEqual(
            LibraryPaths.relativePath(of: url, under: root),
            "Artist/Album/01 Song.flac"
        )
        XCTAssertEqual(
            LibraryPaths.relativePath(of: url),
            canonicalSyncPath("Artist/Album/01 Song.flac")
        )
        XCTAssertNil(LibraryPaths.relativePath(of: URL(fileURLWithPath: "/elsewhere/song.flac"), under: root))
    }

    func testTenThousandTrackLookupsStayOffTheDisk() {
        let root = LibraryPaths.root
        let urls = (0..<10_000).map { index in
            root.appendingPathComponent("Artist \(index % 400)/Album \(index % 900)/\(index).flac", isDirectory: false)
        }
        let started = Date()
        for url in urls {
            _ = LibraryPaths.relativePath(of: url)
        }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 2, "10 000 track paths took \(elapsed)s, which means a file lookup came back")
    }

    /// The owner's library: 638 albums and 7 105 songs. Every chip must pivot it
    /// in milliseconds, because anything that reads the disk per song turns this
    /// into the multi-second beachball the pivot used to be.
    func testEveryChipPivotsTheOwnersLibraryInMilliseconds() {
        var albums: [Album] = []
        var meta = [String: LibraryViewModel.TrackMeta]()
        albums.reserveCapacity(638)
        meta.reserveCapacity(7_018)
        for albumIndex in 0..<638 {
            let title = "Album \(albumIndex)"
            let songs = (0..<11).map { trackIndex in
                track("Song \(trackIndex)", album: title)
            }
            albums.append(album(title, tracks: songs))
            for (songIndex, song) in songs.enumerated() {
                let played = albumIndex % 3 == 0 ? nil : daysAgo(Double(albumIndex % 400 + songIndex))
                meta.merge([self.meta(song, added: daysAgo(Double(albumIndex % 900)), played: played, plays: albumIndex % 5)]) { first, _ in first }
            }
        }
        let songs = albums.flatMap(\.tracks)

        let started = Date()
        let signals = LibraryViewModel.buildFilterSignals(albums: albums, meta: meta, now: now)
        let addedAlbumIds = LibraryFilterRules.recentlyAdded(
            albums.map { (id: LibraryViewModel.albumFilterKey($0), dateAdded: signals.added[LibraryViewModel.albumFilterKey($0)] ?? .distantPast) },
            now: now, thresholds: .albums
        )
        let playedAlbumIds = LibraryFilterRules.recentlyPlayed(
            albums.map { (id: LibraryViewModel.albumFilterKey($0), lastPlayed: signals.played[LibraryViewModel.albumFilterKey($0)]) },
            now: now, thresholds: .albums
        )
        let rediscoverKeys = signals.rediscover.keys
        let rediscoverAlbums = albums.filter { rediscoverKeys.contains(LibraryViewModel.albumFilterKey($0)) }
        let addedSongIds = LibraryFilterRules.recentlyAdded(
            songs.map { song in
                let path = LibraryPaths.relativePath(of: song.fileURL)
                return (id: path, dateAdded: meta[path]?.dateAdded ?? .distantPast)
            },
            now: now, thresholds: .songs
        )
        let playedSongIds = LibraryFilterRules.recentlyPlayed(
            songs.map { song in
                let path = LibraryPaths.relativePath(of: song.fileURL)
                return (id: path, lastPlayed: meta[path]?.lastPlayed)
            },
            now: now, thresholds: .songs
        )
        let elapsed = Date().timeIntervalSince(started)

        let albumKeys = Set(albums.map(LibraryViewModel.albumFilterKey))
        XCTAssertFalse(addedAlbumIds.isEmpty)
        XCTAssertTrue(addedAlbumIds.allSatisfy(albumKeys.contains))
        XCTAssertTrue(playedAlbumIds.allSatisfy(albumKeys.contains))
        XCTAssertFalse(rediscoverAlbums.isEmpty)
        XCTAssertEqual(addedSongIds.count, Set(addedSongIds).count)
        XCTAssertFalse(playedSongIds.isEmpty)
        XCTAssertLessThan(elapsed, 0.5, "the six chips took \(elapsed)s over 7 018 songs, which means a lookup went to the disk")
    }
}
