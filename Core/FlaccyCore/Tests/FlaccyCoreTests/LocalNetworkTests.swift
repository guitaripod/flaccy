import XCTest
@testable import FlaccyCore

final class LocalNetworkTests: XCTestCase {

    func testThePrivateIPv4RangesAndLinkLocalAreLocal() {
        for local in ["10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.1.20", "169.254.3.4"] {
            XCTAssertTrue(LocalNetwork.isLocalNetwork(local), local)
        }
        for other in ["172.32.0.1", "192.169.0.1", "100.64.0.1", "100.91.211.44", "8.8.8.8", "127.0.0.1"] {
            XCTAssertFalse(LocalNetwork.isLocalNetwork(other), other)
        }
    }

    func testUniqueLocalAndLinkLocalIPv6AreLocalButTheTailnetPrefixIsNot() {
        XCTAssertTrue(LocalNetwork.isLocalNetwork("fd12:3456::1"))
        XCTAssertTrue(LocalNetwork.isLocalNetwork("fc00::1"))
        XCTAssertTrue(LocalNetwork.isLocalNetwork("fe80::1%en0"))
        XCTAssertFalse(LocalNetwork.isLocalNetwork("fd7a:115c:a1e0::1"))
        XCTAssertFalse(LocalNetwork.isLocalNetwork("2001:db8::1"))
        XCTAssertFalse(LocalNetwork.isLocalNetwork("::1"))
    }

    func testMappedAddressesCountAsTheAddressTheyWrap() {
        XCTAssertTrue(LocalNetwork.isLocalNetwork("::ffff:192.168.1.5"))
        XCTAssertFalse(LocalNetwork.isLocalNetwork("::ffff:100.64.0.1"))
    }

    func testLocalHostsAreLocalIPsAndBonjourNames() {
        XCTAssertTrue(LocalNetwork.isLocalHost("192.168.1.5"))
        XCTAssertTrue(LocalNetwork.isLocalHost("[fd12::5]"))
        XCTAssertTrue(LocalNetwork.isLocalHost("Marcuss-MacBook-Pro.local"))
        XCTAssertTrue(LocalNetwork.isLocalHost("arch.LOCAL."))
        XCTAssertFalse(LocalNetwork.isLocalHost(".local"))
        XCTAssertFalse(LocalNetwork.isLocalHost("arch"))
        XCTAssertFalse(LocalNetwork.isLocalHost("arch.tail1234.ts.net"))
        XCTAssertFalse(LocalNetwork.isLocalHost("100.91.211.44"))
        XCTAssertFalse(LocalNetwork.isLocalHost("music.example.com"))
    }
}
