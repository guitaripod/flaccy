import FlaccyCore
import XCTest
@testable import flaccy

/// The Apple half of the chart-queue proof; `linux/src/chart_queue.rs` carries
/// the same five cases, and the two artist-track cases mirror the ones in
/// `linux/library/src/library.rs`. A top list plays whatever the library owns
/// behind it, so what must hold is rank order, skipping what is not owned,
/// matching through the casing and punctuation Last.fm disagrees with the tags
/// about, and never queueing a song twice.
nonisolated final class RecapLibraryIndexTests: XCTestCase {

    private func track(_ path: String, _ title: String, artist: String, album: String) -> Track {
        Track(
            fileURL: URL(fileURLWithPath: "/library/\(path)"),
            title: title, artist: artist, albumTitle: album, albumArtist: nil,
            trackNumber: 1, duration: 100, artwork: nil, dbID: nil
        )
    }

    private func makeIndex() -> RecapLibraryIndex {
        let domino = track("a/1.flac", "Domino", artist: "Cascada", album: "Evacuate the Dancefloor")
        let evacuate = track("a/2.flac", "Evacuate the Dancefloor", artist: "Cascada", album: "Evacuate the Dancefloor")
        let agaetis = track("b/1.flac", "Ágætis byrjun", artist: "Sigur Rós", album: "Ágætis byrjun")
        let heroes = track("c/1.flac", "Heroes — 2017 Remaster", artist: "David Bowie", album: "Heroes")
        let albums = [
            Album(title: "Evacuate the Dancefloor", artist: "Cascada", artwork: nil, tracks: [domino, evacuate], year: nil, genre: nil),
            Album(title: "Ágætis byrjun", artist: "Sigur Rós", artwork: nil, tracks: [agaetis], year: nil, genre: nil),
            Album(title: "Heroes", artist: "David Bowie", artwork: nil, tracks: [heroes], year: nil, genre: nil),
        ]
        return RecapLibraryIndex(albums: albums, tracks: albums.flatMap(\.tracks))
    }

    private func paths(_ tracks: [Track]) -> [String] {
        tracks.map { $0.fileURL.path.replacingOccurrences(of: "/library/", with: "") }
    }

    private func charted(_ name: String, by artist: String, rank: Int) -> ChartTrack {
        ChartTrack(rank: rank, name: name, artistName: artist, playCount: 1)
    }

    func testTrackQueueKeepsRankOrderAndSkipsUnowned() {
        let queue = makeIndex().queue(forTracks: [
            charted("Evacuate the Dancefloor", by: "Cascada", rank: 1),
            charted("Nothing I Own", by: "Nobody", rank: 2),
            charted("Domino", by: "Cascada", rank: 3),
        ])
        XCTAssertEqual(paths(queue), ["a/2.flac", "a/1.flac"])
    }

    func testMatchingIgnoresCaseDiacriticsAndPunctuation() {
        let index = makeIndex()
        XCTAssertNotNil(index.track(title: "agætis byrjun", artist: "SIGUR ROS"))
        XCTAssertNotNil(index.track(title: "domino!!", artist: "cascada"))
        XCTAssertNotNil(index.album(name: "evacuate the dancefloor", artist: "CASCADA"))
        XCTAssertNil(index.album(name: "Evacuate The Dancefloor", artist: "Somebody Else"))
    }

    func testATitleContainingTheSeparatorStillResolves() {
        let queue = makeIndex().queue(forTracks: [charted("Heroes — 2017 Remaster", by: "David Bowie", rank: 1)])
        XCTAssertEqual(paths(queue), ["c/1.flac"])
    }

    func testAlbumQueuePlaysEachReleaseWholeInRankOrder() {
        let queue = makeIndex().queue(forAlbums: [
            ChartAlbum(rank: 1, name: "Heroes", artistName: "David Bowie", playCount: 1, imageURL: nil),
            ChartAlbum(rank: 2, name: "Evacuate the Dancefloor", artistName: "Cascada", playCount: 1, imageURL: nil),
        ])
        XCTAssertEqual(paths(queue), ["c/1.flac", "a/1.flac", "a/2.flac"])
    }

    func testArtistQueueIsDeduplicatedAcrossTheChart() {
        let index = makeIndex()
        let queue = index.queue(forArtists: [
            ChartArtist(rank: 1, name: "Cascada", playCount: 1),
            ChartArtist(rank: 2, name: "Cascada", playCount: 1),
            ChartArtist(rank: 3, name: "Sigur Rós", playCount: 1),
            ChartArtist(rank: 4, name: "Nobody", playCount: 1),
        ])
        XCTAssertEqual(paths(queue), ["a/1.flac", "a/2.flac", "b/1.flac"])
        XCTAssertTrue(index.tracks(byArtist: "Nobody").isEmpty)
    }

    /// The library `mixed_library()` builds in `linux/library/src/library.rs`: a
    /// soundtrack two composers perform on, one composer's own albums, an empty
    /// album, credits that fold to nothing, and a credit only diacritics tell apart.
    private func mixedLibrary() -> [Album] {
        func album(_ title: String, _ artist: String, _ tracks: [(String, String)]) -> Album {
            Album(
                title: title, artist: artist, artwork: nil,
                tracks: tracks.map { track("\($0.0).flac", $0.0, artist: $0.1, album: title) }, year: nil, genre: nil
            )
        }
        return [
            album("Soundtrack", "Various Artists", [("s/1", "Composer A"), ("s/2", "composer a feat. Guest"), ("s/3", "Composer B")]),
            album("Own", "Composer A", [("o/1", "Composer A"), ("o/2", "Composer B")]),
            album("Empty", "Nobody", []),
            album("Punctuation", "?!", [("p/1", "...")]),
            album("Sigur", "Sigur Rós", [("g/1", "Sigur Ros")]),
            album("Again", "Composer A", [("o/3", "Someone Else")]),
        ]
    }

    /// What the index must answer for an artist: walk every album, taking it
    /// whole when it is credited to them and otherwise each track they perform.
    private func walkingTracks(byArtist artist: String, in albums: [Album]) -> [Track] {
        let key = LibraryHygiene.artistKey(artist)
        return albums.flatMap { album -> [Track] in
            if LibraryHygiene.artistKey(album.artist) == key { return album.tracks }
            return album.tracks.filter { LibraryHygiene.artistKey($0.artist) == key }
        }
    }

    func testArtistTracksMatchWalkingEveryAlbumAndTrack() {
        let albums = mixedLibrary()
        let index = RecapLibraryIndex(albums: albums, tracks: albums.flatMap(\.tracks))
        for artist in [
            "Composer A", "COMPOSER B", "Various Artists", "Nobody", "?!", "",
            "Sigur Rós", "sigur ros", "Absent", "Composer A feat. Guest",
        ] {
            XCTAssertEqual(
                paths(index.tracks(byArtist: artist)), paths(walkingTracks(byArtist: artist, in: albums)), artist
            )
        }
    }

    func testArtistTracksKeepAlbumOrderWithCreditedAlbumsWhole() {
        let albums = mixedLibrary()
        let index = RecapLibraryIndex(albums: albums, tracks: albums.flatMap(\.tracks))
        XCTAssertEqual(
            paths(index.tracks(byArtist: "Composer A")), ["s/1.flac", "s/2.flac", "o/1.flac", "o/2.flac", "o/3.flac"]
        )
    }
}
