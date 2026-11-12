import XCTest
@testable import FlaccyCore

final class CertificatePinTests: XCTestCase {

    func testBase64URLIsUnpaddedAndURLSafe() {
        XCTAssertEqual(CertificatePin.base64url(Data([0xfb, 0xff])), "-_8")
        XCTAssertEqual(CertificatePin.base64url(Data("Man".utf8)), "TWFu")
        XCTAssertEqual(CertificatePin.base64url(Data("Ma".utf8)), "TWE")
        XCTAssertEqual(CertificatePin.base64url(Data()), "")
    }

    func testPinsCompareExactlyAfterTrimming() {
        XCTAssertTrue(CertificatePin.matches(" abc ", "abc"))
        XCTAssertFalse(CertificatePin.matches("abc", "abd"))
        XCTAssertFalse(CertificatePin.matches("", ""))
    }

    #if canImport(CryptoKit)
    func testThePinIsTheSameTheRustSideAsserts() {
        let raw = Data([4] + (1...64).map { UInt8($0) })
        XCTAssertEqual(CertificatePin.pin(ofPublicKey: raw), "DtOmq5V_9vWaljCkc9MafQT8tGVIuJAWGWmAx-llhPY")
        XCTAssertEqual(CertificatePin.pin(ofPublicKey: Data()), "47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU")
    }
    #endif
}
