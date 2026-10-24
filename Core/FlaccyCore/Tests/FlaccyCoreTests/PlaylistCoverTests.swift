import XCTest
@testable import FlaccyCore

final class PlaylistCoverTests: XCTestCase {

    func testP1KeyRoundTripsThePlaylistId() {
        let title = PlaylistCover.title(forPlaylist: 42)
        XCTAssertEqual(title, "playlist:42")
        XCTAssertEqual(PlaylistCover.playlistId(title: title, artist: PlaylistCover.artist), 42)
    }

    func testP2AnOrdinaryAlbumIsNeverAPlaylistKey() {
        XCTAssertNil(PlaylistCover.playlistId(title: "playlist:42", artist: "Some Band"))
        XCTAssertNil(PlaylistCover.playlistId(title: "Abbey Road", artist: PlaylistCover.artist))
        XCTAssertNil(PlaylistCover.playlistId(title: "playlist:x", artist: PlaylistCover.artist))
    }

    func testP3MosaicTakesFirstFourDistinctAlbumsInOrder() {
        let albums = [("A", "x"), ("A", "x"), ("B", "x"), ("A", "y"), ("C", "z"), ("D", "z"), ("E", "z")]
        let kept = PlaylistCover.mosaicAlbums(albums.map { (title: $0.0, artist: $0.1) })
        XCTAssertEqual(kept.map { "\($0.title)|\($0.artist)" }, ["A|x", "B|x", "A|y", "C|z"])
    }

    func testP4TracksWithoutAnAlbumTitleAreSkipped() {
        let kept = PlaylistCover.mosaicAlbums([(title: "", artist: "x"), (title: "B", artist: "x")])
        XCTAssertEqual(kept.map(\.title), ["B"])
    }

    func testP5ShelfHoldsUpToTwelveDistinctAlbums() {
        let albums = (0..<20).map { (title: "Album \($0 % 15)", artist: "x") }
        XCTAssertEqual(PlaylistCover.shelfAlbums(albums).count, 12)
    }
}
