import XCTest
@testable import FlaccyCore

final class SyncInventoryTests: XCTestCase {

    func testInsertTracksSizesAndCount() {
        var inventory = SyncInventory()
        XCTAssertTrue(inventory.insert(path: "A/B/01.m4a", size: 100).isEmpty)
        XCTAssertTrue(inventory.insert(path: "A/B/02.m4a", size: 250).isEmpty)
        XCTAssertEqual(inventory.count, 2)
        XCTAssertEqual(inventory.usedBytes, 350)
        XCTAssertEqual(inventory.paths, ["A/B/01.m4a", "A/B/02.m4a"])
    }

    func testInsertReturnsSameStemSiblingsAndForgetsThem() {
        var inventory = SyncInventory(["A/B/01.flac": 900])
        let siblings = inventory.insert(path: "A/B/01.m4a", size: 100)
        XCTAssertEqual(siblings, ["A/B/01.flac"])
        XCTAssertEqual(inventory.paths, ["A/B/01.m4a"])
        XCTAssertEqual(inventory.usedBytes, 100)
        XCTAssertEqual(inventory.count, 1)
    }

    func testInsertSamePathReplacesSizeWithoutSiblings() {
        var inventory = SyncInventory(["A/01.m4a": 100])
        XCTAssertTrue(inventory.insert(path: "A/01.m4a", size: 300).isEmpty)
        XCTAssertEqual(inventory.usedBytes, 300)
        XCTAssertEqual(inventory.count, 1)
    }

    func testInsertDisplacesEverySibling() {
        var inventory = SyncInventory()
        inventory.insert(path: "X/s.flac", size: 5)
        let displaced = inventory.insert(path: "X/s.mp3", size: 4)
        XCTAssertEqual(displaced, ["X/s.flac"])
        let again = inventory.insert(path: "X/s.m4a", size: 3)
        XCTAssertEqual(again, ["X/s.mp3"])
        XCTAssertEqual(inventory.paths, ["X/s.m4a"])
    }

    func testDifferentStemsAreNotSiblings() {
        var inventory = SyncInventory(["A/01.flac": 1])
        XCTAssertTrue(inventory.insert(path: "A/02.m4a", size: 1).isEmpty)
        XCTAssertTrue(inventory.insert(path: "B/01.m4a", size: 1).isEmpty)
        XCTAssertEqual(inventory.count, 3)
    }

    func testStemKeepsDotsInTitle() {
        var inventory = SyncInventory(["A/Vol. 1.flac": 1])
        XCTAssertEqual(inventory.insert(path: "A/Vol. 1.m4a", size: 1), ["A/Vol. 1.flac"])
        XCTAssertTrue(inventory.insert(path: "A/Vol. 2.m4a", size: 1).isEmpty)
    }

    func testExtensionCaseDoesNotChangeTheStem() {
        var inventory = SyncInventory(["A/01.FLAC": 1])
        XCTAssertEqual(inventory.insert(path: "A/01.m4a", size: 1), ["A/01.FLAC"])
    }

    func testNFDAndNFCNamesAreTheSameTrack() {
        let nfc = "Bjo\u{308}rk/Vespertine/01 Hidden Place.flac".precomposedStringWithCanonicalMapping
        let nfd = "Bjo\u{308}rk/Vespertine/01 Hidden Place.m4a".decomposedStringWithCanonicalMapping
        var inventory = SyncInventory()
        inventory.insert(path: nfc, size: 10)
        let displaced = inventory.insert(path: nfd, size: 4)
        XCTAssertEqual(displaced, [nfc])
        XCTAssertEqual(inventory.count, 1)
        XCTAssertTrue(inventory.contains(stem: "Bjo\u{308}rk/Vespertine/01 Hidden Place".decomposedStringWithCanonicalMapping))
        XCTAssertEqual(inventory.paths, [nfd.precomposedStringWithCanonicalMapping])
    }

    func testRemovePath() {
        var inventory = SyncInventory(["A/01.m4a": 10, "A/02.m4a": 20])
        XCTAssertTrue(inventory.remove(path: "A/01.m4a"))
        XCTAssertFalse(inventory.remove(path: "A/01.m4a"))
        XCTAssertFalse(inventory.contains(stem: "A/01"))
        XCTAssertEqual(inventory.usedBytes, 20)
    }

    func testRemovePathWithOtherExtensionDoesNotTouchTheStoredFile() {
        var inventory = SyncInventory(["A/01.m4a": 10])
        XCTAssertFalse(inventory.remove(path: "A/01.flac"))
        XCTAssertEqual(inventory.count, 1)
    }

    func testRemoveStemReturnsStoredPaths() {
        var inventory = SyncInventory(["A/01.m4a": 10, "A/02.m4a": 20])
        XCTAssertEqual(inventory.remove(stem: "A/01"), ["A/01.m4a"])
        XCTAssertEqual(inventory.remove(stem: "A/01"), [])
        XCTAssertEqual(inventory.paths, ["A/02.m4a"])
        XCTAssertFalse(inventory.contains(stem: "A/01"))
    }

    func testRemoveStemMatchesFromAFlacPath() {
        var inventory = SyncInventory(["A/01.m4a": 10])
        XCTAssertEqual(inventory.remove(stem: SyncStem.of("A/01.flac")), ["A/01.m4a"])
        XCTAssertTrue(inventory.isEmpty)
    }

    func testInitFromDictionaryCollapsesSiblings() {
        let inventory = SyncInventory(["A/01.flac": 900, "A/01.m4a": 100, "A/02.mp3": 50])
        XCTAssertEqual(inventory.count, 2)
        XCTAssertEqual(inventory.paths.filter { $0.hasPrefix("A/01") }.count, 1)
        XCTAssertEqual(inventory.size(of: "A/02.mp3"), 50)
    }

    func testNegativeSizeIsClampedToZero() {
        var inventory = SyncInventory()
        inventory.insert(path: "A/01.m4a", size: -5)
        XCTAssertEqual(inventory.usedBytes, 0)
    }

    func testEmptyInventory() {
        let inventory = SyncInventory()
        XCTAssertEqual(inventory.count, 0)
        XCTAssertEqual(inventory.usedBytes, 0)
        XCTAssertEqual(inventory.paths, [])
        XCTAssertFalse(inventory.contains(stem: "anything"))
    }

    func testRemoveAll() {
        var inventory = SyncInventory(["A/01.m4a": 10])
        inventory.removeAll()
        XCTAssertTrue(inventory.isEmpty)
        XCTAssertFalse(inventory.contains(stem: "A/01"))
    }

    func testScanningReadsSizesOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("inventory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let album = root.appendingPathComponent("Artist/Album")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        try Data(count: 64).write(to: album.appendingPathComponent("01.m4a"))
        try Data(count: 32).write(to: album.appendingPathComponent("02.flac"))
        try Data(count: 8).write(to: album.appendingPathComponent("cover.jpg"))
        try Data(count: 8).write(to: album.appendingPathComponent(".03.m4a.flaccy-part"))

        let inventory = SyncInventory.scanning(directory: root)
        XCTAssertEqual(inventory.paths, ["Artist/Album/01.m4a", "Artist/Album/02.flac"])
        XCTAssertEqual(inventory.usedBytes, 96)
    }

    func testScanningMissingDirectoryIsEmpty() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString)")
        XCTAssertTrue(SyncInventory.scanning(directory: missing).isEmpty)
    }
}

final class SyncPathGuardTests: XCTestCase {

    func testAcceptsOrdinaryPaths() {
        XCTAssertTrue(SyncPathGuard.isSafe("track.m4a"))
        XCTAssertTrue(SyncPathGuard.isSafe("Artist/Album/01 Song.m4a"))
        XCTAssertTrue(SyncPathGuard.isSafe("Artist/Album (Deluxe)/01 - Song, Pt. 2.flac"))
    }

    func testAcceptsUnicodeInBothForms() {
        let name = "Bjo\u{308}rk/Homogenic/01 Jo\u{308}ga.flac"
        XCTAssertTrue(SyncPathGuard.isSafe(name))
        XCTAssertTrue(SyncPathGuard.isSafe(name.precomposedStringWithCanonicalMapping))
        XCTAssertTrue(SyncPathGuard.isSafe("坂本龍一/async/01 andata.m4a"))
        XCTAssertTrue(SyncPathGuard.isSafe("Artist/Album/😀.m4a"))
    }

    func testAcceptsSpacesAndDotsInNames() {
        XCTAssertTrue(SyncPathGuard.isSafe("Artist Name/Vol. 1/01 Song.m4a"))
        XCTAssertTrue(SyncPathGuard.isSafe("...And Justice for All/01 Blackened.flac"))
        XCTAssertTrue(SyncPathGuard.isSafe("a..b/c..d.m4a"))
        XCTAssertTrue(SyncPathGuard.isSafe("Artist/Album/..hidden-ish.m4a"))
        XCTAssertTrue(SyncPathGuard.isSafe("Artist/Album/...m4a"))
        XCTAssertTrue(SyncPathGuard.isSafe("A/./b.m4a"))
    }

    func testRejectsEmptyAndAbsolute() {
        XCTAssertFalse(SyncPathGuard.isSafe(""))
        XCTAssertFalse(SyncPathGuard.isSafe("/"))
        XCTAssertFalse(SyncPathGuard.isSafe("/etc/passwd"))
        XCTAssertFalse(SyncPathGuard.isSafe("/var/mobile/a.m4a"))
    }

    func testRejectsTraversal() {
        XCTAssertFalse(SyncPathGuard.isSafe(".."))
        XCTAssertFalse(SyncPathGuard.isSafe("../a.m4a"))
        XCTAssertFalse(SyncPathGuard.isSafe("a/../../b.m4a"))
        XCTAssertFalse(SyncPathGuard.isSafe("a/b/../../../etc/passwd"))
        XCTAssertFalse(SyncPathGuard.isSafe("a/.."))
        XCTAssertFalse(SyncPathGuard.isSafe("a//../..//b.m4a"))
        XCTAssertFalse(SyncPathGuard.isSafe("./../a.m4a"))
    }

    func testRejectsTraversalThatReturnsInside() {
        XCTAssertFalse(SyncPathGuard.isSafe("a/../a/b.m4a"))
    }

    func testRejectsNulByte() {
        XCTAssertFalse(SyncPathGuard.isSafe("a\u{0}.m4a"))
        XCTAssertFalse(SyncPathGuard.isSafe("a/b.m4a\u{0}../../x"))
    }

    func testRejectsPathsThatNameNoFile() {
        XCTAssertFalse(SyncPathGuard.isSafe("."))
        XCTAssertFalse(SyncPathGuard.isSafe("./"))
        XCTAssertFalse(SyncPathGuard.isSafe("a/b/"))
        XCTAssertFalse(SyncPathGuard.isSafe("a/."))
        XCTAssertFalse(SyncPathGuard.isSafe("//"))
    }
}
