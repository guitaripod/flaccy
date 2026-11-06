import XCTest
@testable import FlaccyCore

final class IndexedLibraryRecordTests: XCTestCase {

    private var folder: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "IndexedLibraryRecordTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexedLibraryRecordTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private var record: IndexedLibraryRecord { IndexedLibraryRecord(folder: folder, defaults: defaults) }

    private var markerExists: Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(IndexedLibraryRecord.markerName).path)
    }

    func testAFreshInstallHasNoIndexedLibrary() {
        XCTAssertFalse(record.hadIndexedLibrary)
    }

    func testMarkingCreatesTheFolderAndTheFile() {
        record.markIndexed()
        XCTAssertTrue(markerExists)
        XCTAssertTrue(record.hadIndexedLibrary)
    }

    func testTheFileHoldsWhenThePreferencesReadBackEmpty() {
        record.markIndexed()
        defaults.removePersistentDomain(forName: suiteName)
        XCTAssertTrue(IndexedLibraryRecord(folder: folder, defaults: defaults).hadIndexedLibrary)
    }

    func testALibraryIndexedBeforeTheFileExistedStillCounts() {
        defaults.set(true, forKey: IndexedLibraryRecord.legacyDefaultsKey)
        XCTAssertTrue(record.hadIndexedLibrary)
    }

    func testMarkingNeverWritesThePreference() {
        record.markIndexed()
        XCTAssertNil(defaults.object(forKey: IndexedLibraryRecord.legacyDefaultsKey))
    }

    func testMarkingTwiceKeepsOneFile() {
        record.markIndexed()
        record.markIndexed()
        XCTAssertTrue(markerExists)
    }

    func testClearingForgetsTheFileAndThePreference() {
        defaults.set(true, forKey: IndexedLibraryRecord.legacyDefaultsKey)
        record.markIndexed()
        record.clear()
        XCTAssertFalse(markerExists)
        XCTAssertFalse(record.hadIndexedLibrary)
    }
}
