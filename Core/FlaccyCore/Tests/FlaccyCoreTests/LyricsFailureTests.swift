import XCTest
@testable import FlaccyCore

final class LyricsFailureTests: XCTestCase {

    func testStatusesMapToTheFailureAListenerCanActOn() {
        XCTAssertEqual(LyricsFailure.forStatus(429), .busy)
        XCTAssertEqual(LyricsFailure.forStatus(500), .server(500))
        XCTAssertEqual(LyricsFailure.forStatus(503), .server(503))
        XCTAssertEqual(LyricsFailure.forStatus(599), .server(599))
        XCTAssertEqual(LyricsFailure.forStatus(400), .rejected(400))
        XCTAssertEqual(LyricsFailure.forStatus(403), .rejected(403))
    }
}
