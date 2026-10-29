import XCTest
@testable import FlaccyCore

final class ServerSetupInputTests: XCTestCase {

    func testTheCodeIgnoresCaseSpacesAndDashes() {
        XCTAssertEqual(EnrollmentCode.normalized("abcd-efgh jkmn"), "ABCDEFGHJKMN")
        XCTAssertEqual(EnrollmentCode.normalized("  a b\tc\n"), "ABC")
        XCTAssertEqual(EnrollmentCode.normalized("ab_cd.ef"), "ABCDEF")
    }

    func testLookAlikeLettersAreReadAsTheDigitsTheyStandFor() {
        XCTAssertEqual(EnrollmentCode.normalized("oO"), "00")
        XCTAssertEqual(EnrollmentCode.normalized("iIlL"), "1111")
        XCTAssertEqual(EnrollmentCode.normalized("o1il0"), "01110")
    }

    func testTheCodeGroupsInFoursAsItIsTyped() {
        XCTAssertEqual(EnrollmentCode.grouped(""), "")
        XCTAssertEqual(EnrollmentCode.grouped("abc"), "ABC")
        XCTAssertEqual(EnrollmentCode.grouped("abcd"), "ABCD")
        XCTAssertEqual(EnrollmentCode.grouped("abcde"), "ABCD-E")
        XCTAssertEqual(EnrollmentCode.grouped("abcd-efgh-jk"), "ABCD-EFGH-JK")
        XCTAssertEqual(EnrollmentCode.grouped("ABCDEFGHJKMNPQRSTVWXYZ0123"), "ABCD-EFGH-JKMN-PQRS-TVWX-YZ01-23")
    }

    func testGroupingIsStableWhenAppliedTwice() {
        let once = EnrollmentCode.grouped("abcdefghjk")
        XCTAssertEqual(EnrollmentCode.grouped(once), once)
    }

    func testNonASCIILettersAreDropped() {
        XCTAssertEqual(EnrollmentCode.normalized("é-ABC-ß"), "ABC")
    }

    func testAddressesTakeEveryShapeThePersonTypes() throws {
        let cases: [(String, String, String)] = [
            ("arch", "http://arch:4545", "arch"),
            ("ARCH", "http://ARCH:4545", "ARCH"),
            ("  arch  ", "http://arch:4545", "arch"),
            ("arch.tail1234.ts.net", "http://arch.tail1234.ts.net:4545", "arch"),
            ("100.91.211.44", "http://100.91.211.44:4545", "100.91.211.44"),
            ("100.91.211.44:5000", "http://100.91.211.44:5000", "100.91.211.44"),
            ("http://arch", "http://arch:4545", "arch"),
            ("http://arch:8080", "http://arch:8080", "arch"),
            ("arch:8080", "http://arch:8080", "arch"),
            ("http://arch:4545/", "http://arch:4545", "arch"),
        ]
        for (typed, url, name) in cases {
            let input = try XCTUnwrap(ServerAddressInput(typed), typed)
            XCTAssertEqual(input.baseURL.absoluteString, url, typed)
            XCTAssertEqual(input.displayName, name, typed)
        }
    }

    func testAnAddressThatIsNotOneIsRefused() {
        XCTAssertNil(ServerAddressInput(""))
        XCTAssertNil(ServerAddressInput("   "))
        XCTAssertNil(ServerAddressInput("http://"))
        XCTAssertNil(ServerAddressInput("ftp://arch"))
    }

    func testALinkNamesTheServerBeforeItAnswers() throws {
        let link = try XCTUnwrap(FlaccyServerLink(text: "flaccy://server?url=http%3A%2F%2F100.91.211.44%3A4545&enroll=ABCD&name=Study"))
        XCTAssertEqual(ServerAddressInput(link: link).displayName, "Study")
        let unnamed = try XCTUnwrap(FlaccyServerLink(text: "flaccy://server?url=http%3A%2F%2F100.91.211.44%3A4545&enroll=ABCD"))
        XCTAssertEqual(ServerAddressInput(link: unnamed).displayName, "100.91.211.44")
    }
}
