import XCTest
@testable import flaccy

/// The same recording filed on several releases collapses to one row, while
/// different recordings of a song and different songs of one name stay apart.
nonisolated final class DuplicateSongsTests: XCTestCase {

    private func track(
        _ title: String, artist: String = "Aurelia Vance", album: String, duration: TimeInterval = 215,
        codec: String? = "FLAC", bitDepth: Int? = 16, id: Int64 = 1, number: Int = 1
    ) -> Track {
        Track(
            fileURL: URL(fileURLWithPath: "/lib/\(artist)/\(album)/\(number) \(title).flac"),
            title: title, artist: artist, albumTitle: album, albumArtist: nil,
            trackNumber: number, duration: duration, artwork: nil, dbID: id,
            codec: codec, bitDepth: bitDepth, sampleRate: 44_100, channels: 2
        )
    }

    @MainActor func testSameSongOnTwoAlbumsCollapsesToOne() {
        let single = track("Glass Harbor", album: "Glass Harbor - Single", id: 1)
        let album = track("Glass Harbor", album: "Tidewater", duration: 216, id: 2)
        let result = LibraryHygiene.collapsingDuplicateSongs([single, album])
        XCTAssertEqual(result.tracks.count, 1)
        XCTAssertEqual(result.copies.values.first?.count, 1)
    }

    @MainActor func testRemasterSuffixIsTheSameSong() {
        let original = track("Glass Harbor", album: "Tidewater", id: 1)
        let remaster = track("Glass Harbor (2011 Remaster)", album: "Tidewater Deluxe", id: 2)
        XCTAssertEqual(LibraryHygiene.collapsingDuplicateSongs([original, remaster]).tracks.count, 1)
    }

    @MainActor func testLiveAndAcousticVersionsStaySeparate() {
        let studio = track("Glass Harbor", album: "Tidewater", id: 1)
        let live = track("Glass Harbor (Live)", album: "Live at the Pier", id: 2)
        let acoustic = track("Glass Harbor - Acoustic", album: "Stripped", id: 3)
        XCTAssertEqual(LibraryHygiene.collapsingDuplicateSongs([studio, live, acoustic]).tracks.count, 3)
    }

    @MainActor func testDifferentLengthsAreDifferentRecordings() {
        let radio = track("Glass Harbor", album: "Singles", duration: 190, id: 1)
        let album = track("Glass Harbor", album: "Tidewater", duration: 261, id: 2)
        XCTAssertEqual(LibraryHygiene.collapsingDuplicateSongs([radio, album]).tracks.count, 2)
    }

    @MainActor func testSameTitleByDifferentArtistsStaysSeparate() {
        let first = track("Intro", artist: "Aurelia Vance", album: "Tidewater", id: 1)
        let second = track("Intro", artist: "Corvid & Crane", album: "Roost", id: 2)
        XCTAssertEqual(LibraryHygiene.collapsingDuplicateSongs([first, second]).tracks.count, 2)
    }

    @MainActor func testKeeperIsTheHighestFidelityCopy() {
        let lossy = track("Glass Harbor", album: "Hits", codec: "MP3", bitDepth: nil, id: 1)
        let hiRes = track("Glass Harbor", album: "Tidewater", codec: "FLAC", bitDepth: 24, id: 2)
        let result = LibraryHygiene.collapsingDuplicateSongs([lossy, hiRes])
        XCTAssertEqual(result.tracks, [hiRes])
    }

    @MainActor func testPreferredCopyBeatsFidelity() {
        let lossy = track("Glass Harbor", album: "Hits", codec: "MP3", bitDepth: nil, id: 1)
        let hiRes = track("Glass Harbor", album: "Tidewater", codec: "FLAC", bitDepth: 24, id: 2)
        let result = LibraryHygiene.collapsingDuplicateSongs([lossy, hiRes]) { $0 == lossy ? 1 : 0 }
        XCTAssertEqual(result.tracks, [lossy])
    }

    @MainActor func testOrderOfSurvivorsIsPreserved() {
        let a = track("Alpha", album: "One", id: 1, number: 1)
        let b = track("Bravo", album: "One", id: 2, number: 2)
        let aCopy = track("Alpha", album: "Two", codec: "MP3", bitDepth: nil, id: 3, number: 1)
        let result = LibraryHygiene.collapsingDuplicateSongs([a, b, aCopy])
        XCTAssertEqual(result.tracks, [a, b])
    }

    @MainActor func testNoDuplicatesReturnsInputUntouched() {
        let tracks = [track("Alpha", album: "One", id: 1), track("Bravo", album: "One", id: 2, number: 2)]
        let result = LibraryHygiene.collapsingDuplicateSongs(tracks)
        XCTAssertEqual(result.tracks, tracks)
        XCTAssertTrue(result.copies.isEmpty)
    }
}
