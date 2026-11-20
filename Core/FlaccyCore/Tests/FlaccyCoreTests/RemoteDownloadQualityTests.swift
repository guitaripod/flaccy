import XCTest
@testable import FlaccyCore

/// Mirrored by the tests in `linux/shared/src/remote/download_quality.rs`.
final class RemoteDownloadQualityTests: XCTestCase {

    func testTheDefaultIsAACAt256() {
        XCTAssertEqual(RemoteDownloadQuality.defaultQuality, .aac256)
        XCTAssertEqual(RemoteDownloadQuality(storedName: nil), .aac256)
        XCTAssertEqual(RemoteDownloadQuality(storedName: "flac"), .aac256)
        XCTAssertEqual(RemoteDownloadQuality(storedName: "original"), .original)
        XCTAssertEqual(RemoteDownloadQuality(storedName: "aac128"), .aac128)
    }

    func testTheOriginalAsksForNoConversion() {
        XCTAssertNil(RemoteDownloadQuality.original.streamParameters(serverType: "flaccy-server"))
        XCTAssertNil(RemoteDownloadQuality.original.kbps)
    }

    func testAFlaccyServerIsAskedForAWholeM4A() {
        let parameters = RemoteDownloadQuality.aac256.streamParameters(serverType: "flaccy-server")
        XCTAssertEqual(parameters?.map(\.0), ["format", "maxBitRate"])
        XCTAssertEqual(parameters?.map(\.1), ["mp4", "256"])
    }

    func testOtherServersAreAskedForAAC() {
        for type in ["navidrome", "gonic", nil] {
            let parameters = RemoteDownloadQuality.aac128.streamParameters(serverType: type)
            XCTAssertEqual(parameters?.map(\.1), ["aac", "128"])
        }
    }

    func testTheSuffixFollowsTheMediaType() {
        XCTAssertEqual(RemoteDownloadQuality.convertedSuffix(contentType: "audio/mp4"), "m4a")
        XCTAssertEqual(RemoteDownloadQuality.convertedSuffix(contentType: "audio/x-m4a"), "m4a")
        XCTAssertEqual(RemoteDownloadQuality.convertedSuffix(contentType: "Audio/AAC; charset=binary"), "aac")
        XCTAssertNil(RemoteDownloadQuality.convertedSuffix(contentType: "audio/flac"))
        XCTAssertNil(RemoteDownloadQuality.convertedSuffix(contentType: "audio/mpeg"))
        XCTAssertNil(RemoteDownloadQuality.convertedSuffix(contentType: nil))
    }
}
