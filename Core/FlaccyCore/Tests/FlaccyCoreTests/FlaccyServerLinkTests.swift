import XCTest
@testable import FlaccyCore

final class FlaccyServerLinkTests: XCTestCase {

    func testTheLinkTheServerPrintsGivesItsAddressCodeAndName() throws {
        let link = try XCTUnwrap(FlaccyServerLink(
            text: "flaccy://server?url=http%3A%2F%2Farch%3A4545&enroll=ABCD-EFGH&name=arch"
        ))
        XCTAssertEqual(link.baseURL.absoluteString, "http://arch:4545")
        XCTAssertEqual(link.enrollmentCode, "ABCD-EFGH")
        XCTAssertEqual(link.name, "arch")
    }

    func testTheAddressDefaultsToPlainHTTPOnPort4545() throws {
        XCTAssertEqual(FlaccyServerLink.baseURL(from: "arch")?.absoluteString, "http://arch:4545")
        XCTAssertEqual(FlaccyServerLink.baseURL(from: "100.91.211.44")?.absoluteString, "http://100.91.211.44:4545")
        XCTAssertEqual(FlaccyServerLink.baseURL(from: "arch.tail1234.ts.net")?.absoluteString, "http://arch.tail1234.ts.net:4545")
        XCTAssertEqual(FlaccyServerLink.baseURL(from: "http://arch:8080/")?.absoluteString, "http://arch:8080")
        XCTAssertEqual(FlaccyServerLink.baseURL(from: "https://arch.example/path?x=1#y")?.absoluteString, "https://arch.example")
        XCTAssertNil(FlaccyServerLink.baseURL(from: "ftp://arch"))
        XCTAssertNil(FlaccyServerLink.baseURL(from: "  "))
    }

    func testALinkWithoutACodeOrAnAddressIsNotAFlaccyServerLink() {
        XCTAssertNil(FlaccyServerLink(text: "flaccy://server?url=http%3A%2F%2Farch%3A4545"))
        XCTAssertNil(FlaccyServerLink(text: "flaccy://server?enroll=ABCD"))
        XCTAssertNil(FlaccyServerLink(text: "flaccy://server?url=http%3A%2F%2Farch&enroll="))
        XCTAssertNil(FlaccyServerLink(text: "https://server?url=arch&enroll=ABCD"))
        XCTAssertNil(FlaccyServerLink(text: "flaccy://auth?url=arch&enroll=ABCD"))
    }

    func testTheOldKeyFormStillParsesAsASubsonicLinkAndNeverAsAFlaccyServerOne() throws {
        let text = "flaccy://server?url=https%3A%2F%2Fbox.example%2Fmusic&key=abc123&name=Home"
        XCTAssertNil(FlaccyServerLink(text: text))
        XCTAssertEqual(ServerLink(text: text)?.apiKey, "abc123")
        guard case .subsonic(let link)? = ParsedServerLink(text: text) else { return XCTFail("not a Subsonic link") }
        XCTAssertEqual(link.address, "https://box.example/music")
    }

    func testALinkWithBothAKeyAndACodeIsAFlaccyServerLink() throws {
        guard case .flaccyServer(let link)? = ParsedServerLink(text: "flaccy://server?url=arch&enroll=CODE&key=ignored") else {
            return XCTFail("not a Flaccy Server link")
        }
        XCTAssertEqual(link.enrollmentCode, "CODE")
        XCTAssertNil(ParsedServerLink(text: "not a link"))
    }

    func testSurroundingWhitespaceIsIgnoredAndTheCodeNeverPrints() throws {
        let link = try XCTUnwrap(FlaccyServerLink(text: "  flaccy://server?url=arch&enroll=SECRETCODE\n"))
        XCTAssertFalse("\(link)".contains("SECRETCODE"))
        XCTAssertEqual(link.baseURL.absoluteString, "http://arch:4545")
    }

    func testNamesAndCodesAreTrimmedAndEmptyNamesDropped() throws {
        let link = try XCTUnwrap(FlaccyServerLink(text: "flaccy://server?url=arch&enroll=%20CODE%20&name=%20"))
        XCTAssertEqual(link.enrollmentCode, "CODE")
        XCTAssertNil(link.name)
    }
}

final class ServerSyncPrimitivesTests: XCTestCase {

    func testUUIDv7IsLowercaseVersionedAndOrderedByTime() {
        let early = ServerSyncIDs.uuidV7(nowMs: 1_700_000_000_000)
        let late = ServerSyncIDs.uuidV7(nowMs: 1_700_000_000_001)
        XCTAssertTrue(ServerSyncIDs.isUUID(early))
        XCTAssertEqual(early[early.index(early.startIndex, offsetBy: 14)], "7")
        XCTAssertTrue("89ab".contains(early[early.index(early.startIndex, offsetBy: 19)]))
        XCTAssertLessThan(early, late)
        XCTAssertNotEqual(ServerSyncIDs.uuidV7(nowMs: 5), ServerSyncIDs.uuidV7(nowMs: 5))
        XCTAssertFalse(ServerSyncIDs.isUUID(early.uppercased()))
    }

    func testScalarKeysFollowTheirPrefixRules() {
        let songKey = String(repeating: "a", count: 32)
        XCTAssertTrue(ServerScalarRules.isValidKey("pref/theme"))
        XCTAssertTrue(ServerScalarRules.isValidKey("eq/profile"))
        XCTAssertTrue(ServerScalarRules.isValidKey("lyr/\(songKey)"))
        XCTAssertTrue(ServerScalarRules.isValidKey("gain/\(songKey)"))
        XCTAssertFalse(ServerScalarRules.isValidKey("gain/short"))
        XCTAssertFalse(ServerScalarRules.isValidKey("lyr/short"))
        XCTAssertFalse(ServerScalarRules.isValidKey("lyr/\(songKey.uppercased())"))
        XCTAssertFalse(ServerScalarRules.isValidKey("nope/x"))
        XCTAssertFalse(ServerScalarRules.isValidKey("pref/"))
        XCTAssertFalse(ServerScalarRules.isValidKey("pref"))
    }

    func testScalarValuesFollowTheirPrefixRules() {
        let songKey = String(repeating: "b", count: 32)
        XCTAssertTrue(ServerScalarRules.isValid(key: "lyr/\(songKey)", value: .int(250)))
        XCTAssertFalse(ServerScalarRules.isValid(key: "lyr/\(songKey)", value: .int(-1)))
        XCTAssertFalse(ServerScalarRules.isValid(key: "lyr/\(songKey)", value: "250"))
        XCTAssertTrue(ServerScalarRules.isValid(key: "meta/\(songKey)", value: ["a": 1]))
        XCTAssertFalse(ServerScalarRules.isValid(key: "meta/\(songKey)", value: 1))
        XCTAssertTrue(ServerScalarRules.isValid(key: "gain/\(songKey)", value: .int(35)))
        XCTAssertTrue(ServerScalarRules.isValid(key: "gain/\(songKey)", value: .int(-240)))
        XCTAssertFalse(ServerScalarRules.isValid(key: "gain/\(songKey)", value: .int(241)))
        XCTAssertFalse(ServerScalarRules.isValid(key: "gain/\(songKey)", value: .double(3.5)))
        XCTAssertEqual(ServerScalarRules.songGainKey(songKey: songKey), "gain/\(songKey)")
        XCTAssertFalse(ServerScalarRules.isValid(key: "pref/big", value: .string(String(repeating: "x", count: 5_000))))
        XCTAssertTrue(ServerScalarRules.isValid(key: "eq/big", value: .string(String(repeating: "x", count: 5_000))))
        XCTAssertFalse(ServerScalarRules.isValid(key: "eq/huge", value: .string(String(repeating: "x", count: 70_000))))
    }

    func testJSONKeepsIntegersAndFractionsApartAndReadsText() throws {
        let value = try XCTUnwrap(ServerJSON(text: #"{"whole":7,"half":0.5,"big":9007199254740993,"none":null,"flag":true,"list":[1,"a"]}"#))
        XCTAssertEqual(value["whole"]?.int, 7)
        XCTAssertEqual(value["big"]?.int, 9_007_199_254_740_993)
        XCTAssertEqual(value["half"], .double(0.5))
        XCTAssertEqual(value["flag"]?.bool, true)
        XCTAssertEqual(value["list"]?.array?.count, 2)
        XCTAssertNil(ServerJSON(text: "{broken"))
        XCTAssertEqual(ServerJSON(text: try XCTUnwrap(value.text)), value)
    }

    func testALocalNetworkLinkCarriesItsPinAndFallbackLikeTheRustSide() throws {
        let link = try XCTUnwrap(FlaccyServerLink(
            text: "flaccy://server?url=https%3A%2F%2Farch.local%3A4545&enroll=ABC&name=arch&pin=Ab-_9&alt=https%3A%2F%2F192.168.1.5%3A4545"
        ))
        XCTAssertEqual(link.baseURL.absoluteString, "https://arch.local:4545")
        XCTAssertEqual(link.pin, "Ab-_9")
        XCTAssertEqual(link.alternateURL?.absoluteString, "https://192.168.1.5:4545")
        XCTAssertEqual(link.candidates.map(\.absoluteString), ["https://arch.local:4545", "https://192.168.1.5:4545"])
        let plain = try XCTUnwrap(FlaccyServerLink(text: "flaccy://server?url=arch&enroll=ABC"))
        XCTAssertNil(plain.pin)
        XCTAssertEqual(plain.candidates.count, 1)
    }

    func testABareLocalNetworkHostGetsHTTPSAndThePort() {
        XCTAssertEqual(FlaccyServerLink.baseURL(from: "192.168.1.5")?.absoluteString, "https://192.168.1.5:4545")
        XCTAssertEqual(FlaccyServerLink.baseURL(from: "Marcuss-Mac.local")?.absoluteString, "https://Marcuss-Mac.local:4545")
        XCTAssertEqual(FlaccyServerLink.baseURL(from: "192.168.1.5:9000")?.absoluteString, "https://192.168.1.5:9000")
        XCTAssertEqual(FlaccyServerLink.baseURL(from: "http://192.168.1.5")?.absoluteString, "http://192.168.1.5:4545")
        XCTAssertEqual(FlaccyServerLink.baseURL(from: "https://192.168.1.5:4545/x")?.absoluteString, "https://192.168.1.5:4545")
    }
}
