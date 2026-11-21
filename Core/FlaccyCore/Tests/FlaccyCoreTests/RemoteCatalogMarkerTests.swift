import XCTest
@testable import FlaccyCore

/// Mirrored by the tests in `linux/shared/src/remote/catalog_marker.rs`, with the same markers and answers.
final class RemoteCatalogMarkerTests: XCTestCase {

    private func marker(_ lastScan: String?, _ count: Int64?) -> RemoteCatalogMarker {
        RemoteCatalogMarker(lastScan: lastScan, count: count)
    }

    func testNothingRememberedMeansChanged() {
        XCTAssertTrue(RemoteCatalogMarker.changed(remembered: nil, current: marker("2026-11-21T16:57:55.328Z", 8081)))
        XCTAssertTrue(RemoteCatalogMarker.changed(remembered: nil, current: marker(nil, nil)))
    }

    func testLastScanDecidesWhenTheServerReportsIt() {
        let seen = marker("2026-11-21T16:57:55.328Z", 8081)
        XCTAssertFalse(RemoteCatalogMarker.changed(remembered: seen, current: marker("2026-11-21T16:57:55.328Z", 8081)))
        XCTAssertTrue(RemoteCatalogMarker.changed(remembered: seen, current: marker("2026-11-21T17:05:00.000Z", 8081)))
        XCTAssertFalse(RemoteCatalogMarker.changed(remembered: seen, current: marker("2026-11-21T16:57:55.328Z", 8090)))
    }

    func testTheCountDecidesWithoutLastScan() {
        let seen = marker(nil, 8081)
        XCTAssertFalse(RemoteCatalogMarker.changed(remembered: seen, current: marker(nil, 8081)))
        XCTAssertTrue(RemoteCatalogMarker.changed(remembered: seen, current: marker(nil, 8129)))
        XCTAssertTrue(RemoteCatalogMarker.changed(remembered: marker("2026-11-21T16:57:55.328Z", 8081), current: marker(nil, 8129)))
    }

    func testAServerThatReportsNeitherIsLeftToThePeriodicSync() {
        XCTAssertFalse(RemoteCatalogMarker.changed(remembered: marker(nil, nil), current: marker(nil, nil)))
        XCTAssertFalse(RemoteCatalogMarker.changed(remembered: marker(nil, 5), current: marker(nil, nil)))
    }

    func testReadsTheMarkerFromAScanStatusAndIgnoresABlankLastScan() throws {
        let blank = SubsonicResponse.ScanStatus(scanning: false, count: 48, lastScan: "  ")
        XCTAssertEqual(RemoteCatalogMarker(status: blank), marker(nil, 48))
        let json = #"{"subsonic-response":{"status":"ok","scanStatus":{"scanning":true,"lastScan":"2026-11-21T16:57:55Z"}}}"#
        let envelope = try SubsonicResponse.decode(Data(json.utf8))
        XCTAssertEqual(RemoteCatalogMarker(status: try XCTUnwrap(envelope.scanStatus)), marker("2026-11-21T16:57:55Z", nil))
    }

    func testStorageRoundTripsAndRefusesForeignText() {
        for value in [marker("2026-11-21T16:57:55.328Z", 8081), marker(nil, 0), marker(nil, nil), marker("x", nil)] {
            XCTAssertEqual(RemoteCatalogMarker(encoded: value.encoded), value)
        }
        XCTAssertEqual(marker("2026-11-21T16:57:55.328Z", 8081).encoded, "8081\t2026-11-21T16:57:55.328Z")
        XCTAssertNil(RemoteCatalogMarker(encoded: "no tab"))
        XCTAssertNil(RemoteCatalogMarker(encoded: "eight\t"))
    }
}
