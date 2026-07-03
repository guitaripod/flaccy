import XCTest
@testable import FlaccyCore

final class FlaccyCoreTests: XCTestCase {

    func testRepeatModeCycles() {
        XCTAssertEqual(RepeatMode.off.next, .all)
        XCTAssertEqual(RepeatMode.all.next, .one)
        XCTAssertEqual(RepeatMode.one.next, .off)
    }

    func testMediaItemIdentityIsRelativePath() {
        let a = MediaItem(relativePath: "x/a.flac", title: "A", artist: "Q", albumTitle: "Z", trackNumber: 1, duration: 10)
        let b = MediaItem(relativePath: "x/a.flac", title: "DIFFERENT", artist: "Q", albumTitle: "Z", trackNumber: 9, duration: 99)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.id, "x/a.flac")
    }

    func testFilenameParserExtractsLeadingTrackNumber() {
        let parsed = FilenameParser.parse("03 - Some Song")
        XCTAssertEqual(parsed.trackNumber, 3)
        XCTAssertEqual(parsed.title, "Some Song")
    }

    func testAlbumGroupingSortsTracks() {
        let items = [
            MediaItem(relativePath: "2.flac", title: "Two", artist: "Artist", albumTitle: "Album", trackNumber: 2, duration: 1),
            MediaItem(relativePath: "1.flac", title: "One", artist: "Artist", albumTitle: "Album", trackNumber: 1, duration: 1),
        ]
        let albums = LibraryScanner.albums(from: items)
        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(albums.first?.items.map(\.trackNumber), [1, 2])
    }

    func testTransferMetadataRoundTrip() {
        let meta = TransferMetadata(relativePath: "Metallica/Justice/01 - Blackened.m4a", title: "Blackened", artist: "Metallica", album: "...And Justice for All", trackNumber: 1, duration: 401)
        let restored = TransferMetadata(dictionary: meta.dictionary)
        XCTAssertEqual(restored, meta)
    }

    func testTransferMetadataRejectsMissingPath() {
        XCTAssertNil(TransferMetadata(dictionary: [SyncKeys.title: "x"]))
        XCTAssertNil(TransferMetadata(dictionary: nil))
    }

    func testMediaItemCodableRoundTrip() throws {
        let item = MediaItem(relativePath: "a/b.m4a", title: "T", artist: "A", albumTitle: "Al", trackNumber: 4, duration: 123, artworkData: Data([0, 1, 2]))
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(MediaItem.self, from: data)
        XCTAssertEqual(decoded, item)
        XCTAssertEqual(decoded.artworkData, Data([0, 1, 2]))
    }
}
