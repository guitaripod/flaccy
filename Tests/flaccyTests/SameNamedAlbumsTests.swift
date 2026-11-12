import XCTest
@testable import flaccy

/// Two groups that show the same title and artist become one album, so every list keyed by
/// `Album.id` holds each identifier once; albums that differ in either stay apart.
nonisolated final class SameNamedAlbumsTests: XCTestCase {

    private func track(_ title: String, album: String, artist: String = "The Beatles", disc: String, number: Int) -> Track {
        Track(
            fileURL: URL(fileURLWithPath: "/lib/\(album)/\(disc)/\(number) \(title).flac"),
            title: title, artist: artist, albumTitle: album, albumArtist: nil,
            trackNumber: number, duration: .infinity, artwork: nil, dbID: Int64(number),
            codec: "FLAC", bitDepth: 16, sampleRate: 44_100, channels: 2
        )
    }

    private func album(_ title: String, artist: String = "The Beatles", year: String? = nil, tracks: [Track]) -> Album {
        Album(title: title, artist: artist, artwork: nil, tracks: tracks, year: year, genre: nil)
    }

    @MainActor func testTwoGroupsShowingTheSameNameBecomeOneAlbumWithEveryTrack() {
        let discOne = album("The White Album", tracks: [
            track("Back in the U.S.S.R.", album: "The White Album", disc: "CD1", number: 1),
            track("Dear Prudence", album: "The White Album", disc: "CD1", number: 2),
        ])
        let discTwo = album("The White Album", year: "1968", tracks: [
            track("Birthday", album: "The White Album", disc: "CD2", number: 1),
        ])
        let merged = LibraryHygiene.mergeSameNamedAlbums([discOne, discTwo])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].tracks.count, 3)
        XCTAssertEqual(merged[0].year, "1968")
        XCTAssertEqual(Set(merged.map(\.id)).count, merged.count)
    }

    @MainActor func testAlbumsThatDifferInTitleOrArtistStayApart() {
        let original = album("Abbey Road", tracks: [track("Come Together", album: "Abbey Road", disc: "A", number: 1)])
        let remaster = album("Abbey Road (Remastered)", tracks: [track("Come Together", album: "Abbey Road (Remastered)", disc: "B", number: 1)])
        let cover = album("Abbey Road", artist: "George Benson", tracks: [
            track("Come Together", album: "Abbey Road", artist: "George Benson", disc: "C", number: 1),
        ])
        let result = LibraryHygiene.mergeSameNamedAlbums([original, remaster, cover])
        XCTAssertEqual(result.map(\.id), [original.id, remaster.id, cover.id])
    }

    @MainActor func testATrackWithAnInfiniteLengthReadsAsZero() {
        XCTAssertEqual(track("Long Night", album: "Endless", disc: "A", number: 1).duration, 0)
    }
}
