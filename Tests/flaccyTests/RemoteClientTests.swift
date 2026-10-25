import FlaccyCore
import Security
import XCTest
@testable import flaccy

nonisolated final class RemoteClientTests: XCTestCase {

    func testRangeHeadersAreHalfOpenOnTheirEnd() {
        XCTAssertEqual(RemoteStreamRange(start: 0, end: 100).headerValue, "bytes=0-99")
        XCTAssertEqual(RemoteStreamRange(start: 500, end: nil).headerValue, "bytes=500-")
    }

    func testAContentRangeGivesTheStartAndTheTotal() {
        let parsed = RemoteStreamHead.parse(contentRange: "bytes 100-199/313276")

        XCTAssertEqual(parsed.start, 100)
        XCTAssertEqual(parsed.total, 313_276)
        XCTAssertNil(RemoteStreamHead.parse(contentRange: "bytes 0-9/*").total)
        XCTAssertNil(RemoteStreamHead.parse(contentRange: "nonsense").start)
    }

    func testAStreamRequestAsksForRawBytesWithRangeAndIfRange() async throws {
        let client = SubsonicClient(
            serverID: "srv", base: URL(string: "http://nas:4533")!, credentials: .password(username: "flaccy", password: "pw")
        )
        let validator = "Sun, 25 Oct 2026 12:48:14 GMT"

        let request = client.streamRequest(id: "song 1", range: RemoteStreamRange(start: 10, end: 20), validator: validator)

        let url = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertTrue(url.hasPrefix("http://nas:4533/rest/stream?id=song%201&format=raw&u=flaccy&t="))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=10-19")
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-Range"), validator)
        XCTAssertNil(client.streamRequest(id: "s", range: RemoteStreamRange(start: 0, end: nil), validator: nil).value(forHTTPHeaderField: "If-Range"))
    }

    func testEveryRequestGetsAFreshSaltAndATokenThatIsNotThePassword() async {
        let client = SubsonicClient(
            serverID: "srv", base: URL(string: "http://nas")!, credentials: .password(username: "u", password: "hunter2")
        )

        let first = client.coverArtURL(id: "c", size: 600).absoluteString
        let second = client.coverArtURL(id: "c", size: 600).absoluteString

        XCTAssertNotEqual(first, second)
        XCTAssertFalse(first.contains("hunter2"))
        XCTAssertTrue(first.contains("size=600"))
    }

    func testFailuresNameTheHostAndWhatToDoNext() {
        let unreachable = RemoteFailure.unreachable(host: "nas.local").errorDescription ?? ""
        let key = RemoteFailure(subsonic: SubsonicFailure(code: 44), code: 44, message: nil, host: "nas.local")
        let token = RemoteFailure(subsonic: SubsonicFailure(code: 41), code: 41, message: nil, host: "nas.local")

        XCTAssertTrue(unreachable.contains("nas.local"))
        XCTAssertEqual(key, .wrongAPIKey(host: "nas.local"))
        XCTAssertEqual(token, .tokenAuthUnsupported(host: "nas.local"))
        XCTAssertEqual(RemoteFailure(subsonic: SubsonicFailure(code: 40), code: 40, message: nil, host: "h"), .wrongPassword(host: "h"))
        XCTAssertEqual(RemoteFailure(subsonic: SubsonicFailure(code: 70), code: 70, message: "gone", host: "h"), .server(code: 70, message: "gone"))
    }

    func testTransportErrorsMapToTheRightFailure() {
        XCTAssertEqual(RemoteFailure(transport: URLError(.serverCertificateUntrusted), host: "h"), .tlsFailure(host: "h"))
        XCTAssertEqual(RemoteFailure(transport: URLError(.cannotConnectToHost), host: "h"), .unreachable(host: "h"))
        XCTAssertEqual(RemoteFailure(transport: URLError(.timedOut), host: "h"), .unreachable(host: "h"))
        XCTAssertEqual(RemoteFailure(transport: URLError(.unsupportedURL), host: "h"), .invalidAddress)
    }

    func testCodecsFollowTheSuffix() {
        XCTAssertEqual(RemoteCatalogSync.codec(suffix: "flac", bitDepth: 16), "FLAC")
        XCTAssertEqual(RemoteCatalogSync.codec(suffix: "m4a", bitDepth: 24), "ALAC")
        XCTAssertEqual(RemoteCatalogSync.codec(suffix: "m4a", bitDepth: 0), "AAC")
        XCTAssertEqual(RemoteCatalogSync.codec(suffix: "aif", bitDepth: nil), "AIFF")
        XCTAssertEqual(RemoteCatalogSync.codec(suffix: "mp3", bitDepth: nil), "MP3")
        XCTAssertNil(RemoteCatalogSync.codec(suffix: nil, bitDepth: nil))
    }

    func testServerDatesParseWithAndWithoutFractionalSeconds() {
        XCTAssertNotNil(RemoteCatalogSync.parseDate("2026-10-25T15:40:34.817723644+02:00"))
        XCTAssertEqual(RemoteCatalogSync.parseDate("2026-10-24T09:15:00Z"), Date(timeIntervalSince1970: 1_792_833_300))
        XCTAssertNil(RemoteCatalogSync.parseDate("yesterday"))
    }

    func testASyncIsDueAfterSixHours() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertTrue(RemoteCatalogSync.isStale(nil, now: now))
        XCTAssertTrue(RemoteCatalogSync.isStale(now.addingTimeInterval(-6 * 3_600 - 1), now: now))
        XCTAssertFalse(RemoteCatalogSync.isStale(now.addingTimeInterval(-6 * 3_600 + 60), now: now))
    }

    func testTheKeychainHoldsASecretAndLetsItGo() throws {
        let backend = KeychainRemoteSecrets(service: "cc.midgarcorp.flaccy.remote-server.tests")
        let store = RemoteCredentialStore(backend: backend)
        let account = UUID().uuidString
        defer { store.removeSecret(for: account) }
        let status = backend.write("probe", account: account)
        try XCTSkipIf(status == errSecMissingEntitlement, "this test host has no keychain entitlement (status \(status))")
        XCTAssertEqual(status, errSecSuccess)

        try store.setSecret("first", for: account)
        XCTAssertEqual(store.secret(for: account), "first")
        try store.setSecret("second", for: account)
        XCTAssertEqual(store.secret(for: account), "second")
        store.removeSecret(for: account)
        XCTAssertNil(store.secret(for: account))
    }
}
