import XCTest
@testable import flaccy

nonisolated final class RemoteLogRedactionTests: XCTestCase {

    func testAPasswordTokenAndItsSaltAreHidden() {
        let line = "GET http://nas:4533/rest/ping?u=flaccy&t=0123456789abcdef&s=cafebabe00112233&v=1.16.1&c=flaccy&f=json failed"

        let redacted = RemoteLogRedaction.redact(line)

        XCTAssertFalse(redacted.contains("0123456789abcdef"))
        XCTAssertFalse(redacted.contains("cafebabe00112233"))
        XCTAssertTrue(redacted.contains("u=flaccy"))
        XCTAssertTrue(redacted.contains("v=1.16.1&c=flaccy&f=json failed"))
    }

    func testAnAPIKeyAndAPlainPasswordAreHidden() {
        let redacted = RemoteLogRedaction.redact("https://h/rest/stream?id=1&apiKey=sekrit-key&p=hunter2&format=raw")

        XCTAssertFalse(redacted.contains("sekrit-key"))
        XCTAssertFalse(redacted.contains("hunter2"))
        XCTAssertTrue(redacted.contains("id=1"))
        XCTAssertTrue(redacted.contains("format=raw"))
    }

    func testTheFirstParameterOfABareQueryIsHidden() {
        XCTAssertEqual(RemoteLogRedaction.redact("t=abc&u=me"), "t=<redacted>&u=me")
    }

    func testPercentEncodedValuesAreHiddenWhole() {
        let redacted = RemoteLogRedaction.redact("?s=a%2Fb%20c&x=1")

        XCTAssertEqual(redacted, "?s=<redacted>&x=1")
    }

    func testTextWithoutSecretsPassesThrough() {
        let line = "Synced nas: 6 songs, 6 new, 0 changed"

        XCTAssertEqual(RemoteLogRedaction.redact(line), line)
    }

    func testAnErrorThatQuotesTheFailingURLIsHidden() {
        let line = "The operation couldn’t be completed. NSErrorFailingURLStringKey=http://nas/rest/ping?t=deadbeef&s=1234"

        XCTAssertFalse(RemoteLogRedaction.redact(line).contains("deadbeef"))
        XCTAssertFalse(RemoteLogRedaction.redact(line).contains("1234"))
    }
}
