import XCTest
@testable import FlaccyCore

final class WiFiTransferProtocolTests: XCTestCase {

    private let token = "k3f9xq"
    private let accepted: Set<String> = ["flac", "mp3", "lrc"]

    private func head(_ text: String) -> WiFiTransferRequestHead? {
        guard case .complete(let head, _) = WiFiTransferRequestHead.parse(Data(text.utf8)) else { return nil }
        return head
    }

    private func route(_ text: String) -> WiFiTransferRoute? {
        head(text).map { WiFiTransferRoute.route($0, token: token, acceptedExtensions: accepted) }
    }

    func testAHeadIsIncompleteUntilTheBlankLine() {
        XCTAssertEqual(WiFiTransferRequestHead.parse(Data("GET /k3f9xq/ HTTP/1.1\r\nHost: x\r\n".utf8)), .incomplete)
    }

    func testTheBodyStartsAfterTheBlankLine() {
        let bytes = Data("PUT /k3f9xq/upload?batch=a&path=x.flac HTTP/1.1\r\nContent-Length: 3\r\n\r\nabc".utf8)
        guard case .complete(let head, let offset) = WiFiTransferRequestHead.parse(bytes) else {
            return XCTFail("expected a head")
        }
        XCTAssertEqual(head.method, "PUT")
        XCTAssertEqual(head.contentLength, 3)
        XCTAssertEqual(String(data: bytes[offset...], encoding: .utf8), "abc")
    }

    func testTheBodyOffsetCountsFromTheStartOfASlice() {
        let whole = Data("xxGET /k3f9xq/ HTTP/1.1\r\n\r\nrest".utf8)
        let slice = whole[2...]
        guard case .complete(_, let offset) = WiFiTransferRequestHead.parse(slice) else { return XCTFail("expected a head") }
        XCTAssertEqual(offset, "GET /k3f9xq/ HTTP/1.1\r\n\r\n".utf8.count)
    }

    func testAHeadTooLongOrNotHTTPIsMalformed() {
        let long = Data(("GET /" + String(repeating: "a", count: WiFiTransferProtocol.maximumHeadLength + 1)).utf8)
        XCTAssertEqual(WiFiTransferRequestHead.parse(long), .malformed)
        XCTAssertEqual(WiFiTransferRequestHead.parse(Data("HELLO\r\n\r\n".utf8)), .malformed)
        XCTAssertEqual(WiFiTransferRequestHead.parse(Data("GET / HTTP/1.1\r\nbroken\r\n\r\n".utf8)), .malformed)
    }

    func testHeaderNamesAreCaseInsensitive() {
        XCTAssertEqual(head("GET /k3f9xq/ HTTP/1.1\r\nCONTENT-LENGTH: 12\r\n\r\n")?.contentLength, 12)
    }

    func testThePageAndEveryRouteSitUnderTheToken() {
        XCTAssertEqual(route("GET /k3f9xq/ HTTP/1.1\r\n\r\n"), .page)
        XCTAssertEqual(route("GET /k3f9xq HTTP/1.1\r\n\r\n"), .page)
        XCTAssertEqual(route("GET / HTTP/1.1\r\n\r\n"), .notFound)
        XCTAssertEqual(route("GET /guess1/ HTTP/1.1\r\n\r\n"), .notFound)
        XCTAssertEqual(route("GET /favicon.ico HTTP/1.1\r\n\r\n"), .notFound)
        XCTAssertEqual(route("DELETE /k3f9xq/upload HTTP/1.1\r\n\r\n"), .notFound)
    }

    func testAnUploadCarriesItsBatchDecodedPathAndLength() {
        let request = "PUT /k3f9xq/upload?batch=b-1&path=Bach%2FGoldberg%2F01%20Aria.flac HTTP/1.1\r\nContent-Length: 2048\r\n\r\n"
        XCTAssertEqual(route(request), .upload(WiFiTransferUpload(batch: "b-1", relativePath: "Bach/Goldberg/01 Aria.flac", length: 2048)))
    }

    func testUploadsThatCannotBeStoredAreRefused() {
        XCTAssertEqual(route("PUT /k3f9xq/upload?batch=b&path=cover.jpg HTTP/1.1\r\nContent-Length: 1\r\n\r\n"), .refuse(.unsupportedFile))
        XCTAssertEqual(route("PUT /k3f9xq/upload?batch=b&path=..%2F..%2Fx.flac HTTP/1.1\r\nContent-Length: 1\r\n\r\n"), .refuse(.badPath))
        XCTAssertEqual(route("PUT /k3f9xq/upload?batch=b&path=x.flac HTTP/1.1\r\n\r\n"), .refuse(.missingLength))
        XCTAssertEqual(route("PUT /k3f9xq/upload?path=x.flac HTTP/1.1\r\nContent-Length: 1\r\n\r\n"), .refuse(.badBatch))
        XCTAssertEqual(route("PUT /k3f9xq/upload?batch=..&path=x.flac HTTP/1.1\r\nContent-Length: 1\r\n\r\n"), .refuse(.badBatch))
        let tooLarge = WiFiTransferProtocol.maximumFileLength + 1
        XCTAssertEqual(route("PUT /k3f9xq/upload?batch=b&path=x.flac HTTP/1.1\r\nContent-Length: \(tooLarge)\r\n\r\n"), .refuse(.tooLarge))
    }

    func testTheExtensionCheckIgnoresCase() {
        XCTAssertEqual(
            route("PUT /k3f9xq/upload?batch=b&path=SONG.FLAC HTTP/1.1\r\nContent-Length: 1\r\n\r\n"),
            .upload(WiFiTransferUpload(batch: "b", relativePath: "SONG.FLAC", length: 1))
        )
    }

    func testDoneNeedsAValidBatch() {
        XCTAssertEqual(route("POST /k3f9xq/done?batch=abc HTTP/1.1\r\nContent-Length: 0\r\n\r\n"), .finish(batch: "abc"))
        XCTAssertEqual(route("POST /k3f9xq/done HTTP/1.1\r\n\r\n"), .refuse(.badBatch))
    }

    func testPathsAreKeptInsideTheirFolder() {
        XCTAssertEqual(WiFiTransferPath.sanitized("Album/01.flac"), "Album/01.flac")
        XCTAssertEqual(WiFiTransferPath.sanitized("/Album//./01.flac"), "Album/01.flac")
        XCTAssertEqual(WiFiTransferPath.sanitized("Album\\Disc 1\\01.flac"), "Album/Disc 1/01.flac")
        XCTAssertNil(WiFiTransferPath.sanitized(""))
        XCTAssertNil(WiFiTransferPath.sanitized("Album/../../escape.flac"))
        XCTAssertNil(WiFiTransferPath.sanitized(".hidden/01.flac"))
        XCTAssertNil(WiFiTransferPath.sanitized("Album/._01.flac"))
        XCTAssertNil(WiFiTransferPath.sanitized("Album/0\u{0}1.flac"))
        XCTAssertNil(WiFiTransferPath.sanitized(Array(repeating: "d", count: 10).joined(separator: "/") + "/x.flac"))
        XCTAssertNil(WiFiTransferPath.sanitized(String(repeating: "é", count: 128) + ".flac"))
    }

    func testTokensAreSixUnambiguousCharacters() {
        for _ in 0..<50 {
            let token = WiFiTransferProtocol.makeToken()
            XCTAssertEqual(token.count, 6)
            XCTAssertTrue(token.allSatisfy { WiFiTransferProtocol.tokenAlphabet.contains($0) })
        }
    }

    func testOnlyPeersOnTheLocalNetworkAreNearby() {
        for host in ["127.0.0.1", "192.168.1.40", "10.0.0.7", "172.20.1.1", "169.254.3.4", "100.101.102.103",
                     "::1", "fe80::1c2a:3bff:fe4d:1234%en0", "fd7a:115c:a1e0::1", "::ffff:192.168.1.40"] {
            XCTAssertTrue(WiFiTransferProtocol.isNearby(host: host), host)
        }
        for host in ["8.8.8.8", "172.32.0.1", "100.128.0.1", "2a00:1450:4001::200e", "::ffff:8.8.8.8", "example.com", "", "1.2.3"] {
            XCTAssertFalse(WiFiTransferProtocol.isNearby(host: host), host)
        }
    }

    func testTheAddressBracketsIPv6AndDropsPort80() {
        XCTAssertEqual(WiFiTransferProtocol.address(host: "192.168.1.23", port: 8080, token: "abc"), "http://192.168.1.23:8080/abc/")
        XCTAssertEqual(WiFiTransferProtocol.address(host: "192.168.1.23", port: 80, token: "abc"), "http://192.168.1.23/abc/")
        XCTAssertEqual(WiFiTransferProtocol.address(host: "fe80::1", port: 8080, token: "abc"), "http://[fe80::1]:8080/abc/")
    }

    func testAResponseClosesTheConnectionAndHeadOmitsTheBody() {
        let full = String(data: WiFiTransferResponse.make(status: 200, contentType: "text/plain", body: Data("hi".utf8)), encoding: .utf8)
        XCTAssertEqual(full?.hasPrefix("HTTP/1.1 200 OK\r\n"), true)
        XCTAssertEqual(full?.contains("Connection: close\r\n"), true)
        XCTAssertEqual(full?.hasSuffix("\r\n\r\nhi"), true)
        let headOnly = String(data: WiFiTransferResponse.make(status: 200, contentType: "text/plain", body: Data("hi".utf8), includeBody: false), encoding: .utf8)
        XCTAssertEqual(headOnly?.contains("Content-Length: 2\r\n"), true)
        XCTAssertEqual(headOnly?.hasSuffix("\r\n\r\n"), true)
        XCTAssertEqual(String(data: WiFiTransferResponse.json(status: 507, error: "space"), encoding: .utf8)?.hasSuffix(#"{"error":"space"}"#), true)
    }
}
