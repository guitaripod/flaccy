import XCTest
@testable import FlaccyCore

/// Mirrored by the tests in `linux/shared/src/remote/server_address.rs`: same inputs, same normalized strings.
final class ServerAddressTests: XCTestCase {

    private func normalized(_ input: String) -> String? {
        ServerAddress.normalize(input)?.absoluteString
    }

    func testBareHostGetsHTTPS() {
        XCTAssertEqual(normalized("music.example.ts.net"), "https://music.example.ts.net")
    }

    func testTrailingSlashAndPortAreKept() {
        XCTAssertEqual(normalized("http://192.168.1.5:4533/"), "http://192.168.1.5:4533")
    }

    func testRestSuffixIsDroppedKeepingThePathPrefix() {
        XCTAssertEqual(normalized("https://h.example/navidrome/rest/"), "https://h.example/navidrome")
        XCTAssertEqual(normalized("https://h.example/navidrome/rest"), "https://h.example/navidrome")
    }

    func testOtherSchemesAreRejected() {
        XCTAssertNil(normalized("ftp://x"))
        XCTAssertNil(normalized("file:///etc"))
    }

    func testEmptyInputIsRejected() {
        XCTAssertNil(normalized(""))
        XCTAssertNil(normalized("   "))
        XCTAssertNil(normalized("https://"))
    }

    func testQueryAndFragmentAreDropped() {
        XCTAssertEqual(normalized("  https://h.example:8443?x=1#y "), "https://h.example:8443")
    }

    func testSchemeIsCaseInsensitive() {
        XCTAssertEqual(normalized("HTTPS://h.example"), "https://h.example")
    }
}
