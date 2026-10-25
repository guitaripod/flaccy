import XCTest
@testable import FlaccyCore

/// Mirrored by the tests in `linux/shared/src/remote/subsonic_request.rs`: the same base, parameters and
/// salt produce the same URL, with the MD5 stand-in returning `md5(<input>)` in both.
final class SubsonicRequestTests: XCTestCase {

    private let fakeMD5: (String) -> String = { "md5(" + $0 + ")" }

    private func build(
        base: String = "https://h.example",
        method: String,
        parameters: [(String, String)] = [],
        credentials: SubsonicCredentials,
        salt: String
    ) -> String {
        SubsonicRequest.url(
            base: URL(string: base)!,
            method: method,
            parameters: parameters,
            credentials: credentials,
            salt: salt,
            md5Hex: fakeMD5
        ).absoluteString
    }

    func testPasswordAuthIsSaltedTokenWithVersionClientAndFormat() {
        let url = build(method: "ping", credentials: .password(username: "ana", password: "pw"), salt: "s1")

        XCTAssertEqual(url, "https://h.example/rest/ping?u=ana&t=md5%28pws1%29&s=s1&v=1.16.1&c=flaccy&f=json")
    }

    func testAPIKeyAuthEncodesParametersAndKeepsThePathPrefix() {
        let url = build(
            base: "https://h.example/nd",
            method: "getAlbum",
            parameters: [("id", "a b/ç")],
            credentials: .apiKey("K+1"),
            salt: "x"
        )

        XCTAssertEqual(url, "https://h.example/nd/rest/getAlbum?id=a%20b%2F%C3%A7&apiKey=K%2B1&v=1.16.1&c=flaccy&f=json")
    }

    func testStreamParametersComeBeforePasswordAuth() {
        let url = build(
            method: "stream",
            parameters: [("id", "42"), ("format", "raw")],
            credentials: .password(username: "ana", password: "pw"),
            salt: "s1"
        )

        XCTAssertEqual(
            url,
            "https://h.example/rest/stream?id=42&format=raw&u=ana&t=md5%28pws1%29&s=s1&v=1.16.1&c=flaccy&f=json"
        )
    }

    func testTrailingSlashOnBaseDoesNotDoubleTheSeparator() {
        let url = build(base: "https://h.example/", method: "ping", credentials: .apiKey("K"), salt: "x")

        XCTAssertEqual(url, "https://h.example/rest/ping?apiKey=K&v=1.16.1&c=flaccy&f=json")
    }

    func testUnreservedBytesAreNotEscapedAndOtherBytesAreUppercase() {
        let url = build(
            method: "search3",
            parameters: [("query", "a-b.c_d~e f&g")],
            credentials: .apiKey("A-z_0.~"),
            salt: "x"
        )

        XCTAssertEqual(
            url,
            "https://h.example/rest/search3?query=a-b.c_d~e%20f%26g&apiKey=A-z_0.~&v=1.16.1&c=flaccy&f=json"
        )
    }

    func testCredentialsRoundTripThroughCodable() throws {
        let original: [SubsonicCredentials] = [.apiKey("K"), .password(username: "ana", password: "pw")]

        let decoded = try JSONDecoder().decode(
            [SubsonicCredentials].self,
            from: try JSONEncoder().encode(original)
        )

        XCTAssertEqual(decoded, original)
    }
}
