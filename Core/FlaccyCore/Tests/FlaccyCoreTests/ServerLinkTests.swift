import XCTest
@testable import FlaccyCore

final class ServerLinkTests: XCTestCase {

    func testTheLinkFlaccyServerPrintsFillsAddressKeyAndName() throws {
        let link = try XCTUnwrap(ServerLink(
            text: "flaccy://server?url=https%3A%2F%2Fbox.tail1234.ts.net%2Fmusic&key=abc123&name=My%20Phone"
        ))
        XCTAssertEqual(link.address, "https://box.tail1234.ts.net/music")
        XCTAssertEqual(link.apiKey, "abc123")
        XCTAssertEqual(link.name, "My Phone")
    }

    func testAMissingNameIsNil() throws {
        let link = try XCTUnwrap(ServerLink(text: "flaccy://server?url=http%3A%2F%2F10.0.0.2%3A4545&key=k"))
        XCTAssertNil(link.name)
    }

    func testSurroundingWhitespaceIsIgnored() {
        XCTAssertNotNil(ServerLink(text: "  flaccy://server?url=x.example&key=k\n"))
    }

    func testOtherLinksAreNotServerLinks() {
        XCTAssertNil(ServerLink(text: "flaccy://auth?token=1"))
        XCTAssertNil(ServerLink(text: "https://server?url=x&key=k"))
        XCTAssertNil(ServerLink(text: "flaccy://server?url=x"))
        XCTAssertNil(ServerLink(text: "flaccy://server?key=k"))
        XCTAssertNil(ServerLink(text: "not a link"))
    }
}
