import XCTest
@testable import FlaccyCore

/// Mirrored by the tests in `linux/shared/src/remote/catalog_diff.rs`, with the same catalogs and buckets.
final class RemoteCatalogDiffTests: XCTestCase {

    private func item(
        _ id: String,
        size: Int64? = 100,
        duration: Double? = 200,
        title: String? = "Title",
        artist: String? = "Artist",
        album: String? = "Album",
        track: Int? = 1,
        fingerprint: String? = nil
    ) -> RemoteCatalogDiff.Item {
        RemoteCatalogDiff.Item(
            id: id, size: size, duration: duration, title: title, artist: artist, album: album, track: track,
            fingerprint: fingerprint
        )
    }

    func testNewServerSongsAreInsertedInServerOrder() {
        let result = RemoteCatalogDiff.diff(server: [item("c"), item("a"), item("b")], local: [item("a")])

        XCTAssertEqual(result.inserted, ["c", "b"])
    }

    func testLocalSongsTheServerNoLongerListsAreRemovedSorted() {
        let result = RemoteCatalogDiff.diff(
            server: [item("a")], local: [item("z"), item("a"), item("m"), item("b")]
        )

        XCTAssertEqual(result.removed, ["b", "m", "z"])
        XCTAssertEqual(result.inserted, [])
    }

    func testMetadataChangeWithSameAudioIsUpdated() {
        let result = RemoteCatalogDiff.diff(
            server: [item("a", title: "Renamed")], local: [item("a")]
        )

        XCTAssertEqual(result.updated, ["a"])
        XCTAssertEqual(result.newVersions, [])
    }

    func testIdenticalSongIsInNoBucket() {
        let result = RemoteCatalogDiff.diff(server: [item("a")], local: [item("a")])

        XCTAssertEqual(result, RemoteCatalogDiff.Result(inserted: [], removed: [], updated: [], newVersions: []))
    }

    func testDifferentFingerprintsAreANewVersionAndNeverAlsoUpdated() {
        let result = RemoteCatalogDiff.diff(
            server: [item("a", size: 120, title: "Renamed", fingerprint: "flac:new")],
            local: [item("a", fingerprint: "flac:old")]
        )

        XCTAssertEqual(result.newVersions, ["a"])
        XCTAssertEqual(result.updated, [])
    }

    func testSameFingerprintWinsOverADifferentSize() {
        let result = RemoteCatalogDiff.diff(
            server: [item("a", size: 999, fingerprint: "flac:same")],
            local: [item("a", size: 100, fingerprint: "flac:same")]
        )

        XCTAssertEqual(result.newVersions, [])
        XCTAssertEqual(result.updated, [])
    }

    func testSameFingerprintWinsOverADifferentSizeWithChangedMetadataUpdatesOnly() {
        let result = RemoteCatalogDiff.diff(
            server: [item("a", size: 999, title: "Renamed", fingerprint: "flac:same")],
            local: [item("a", size: 100, fingerprint: "flac:same")]
        )

        XCTAssertEqual(result.newVersions, [])
        XCTAssertEqual(result.updated, ["a"])
    }

    func testMissingFingerprintFallsBackToSizeForANewVersion() {
        let result = RemoteCatalogDiff.diff(
            server: [item("a", size: 120, fingerprint: "flac:x")],
            local: [item("a", size: 100, fingerprint: nil)]
        )

        XCTAssertEqual(result.newVersions, ["a"])
    }

    func testMissingFingerprintFallsBackToDurationBeyondHalfASecond() {
        let moved = RemoteCatalogDiff.diff(
            server: [item("a", duration: 200.6)], local: [item("a", duration: 200.0)]
        )
        let steady = RemoteCatalogDiff.diff(
            server: [item("a", duration: 200.4)], local: [item("a", duration: 200.0)]
        )

        XCTAssertEqual(moved.newVersions, ["a"])
        XCTAssertEqual(steady.newVersions, [])
    }

    func testEmptyServerListRemovesEverything() {
        let result = RemoteCatalogDiff.diff(server: [], local: [item("b"), item("a")])

        XCTAssertEqual(result.removed, ["a", "b"])
        XCTAssertEqual(result.inserted, [])
        XCTAssertEqual(result.updated, [])
        XCTAssertEqual(result.newVersions, [])
    }
}
