import XCTest
@testable import FlaccyCore

final class LibraryHandoffTests: XCTestCase {

    private var sandbox: URL!
    private var legacyData: URL!
    private var universalData: URL!
    private var group: URL!
    private let exportedAt = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("flaccy-handoff-\(UUID().uuidString)", isDirectory: true)
        legacyData = sandbox.appendingPathComponent("legacy/Application Support/flaccy", isDirectory: true)
        universalData = sandbox.appendingPathComponent("universal/Application Support/flaccy", isDirectory: true)
        group = sandbox.appendingPathComponent("group", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyData, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: universalData, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    @discardableResult
    private func write(_ path: String, in base: URL, bytes: [UInt8]) throws -> URL {
        let url = base.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
        return url
    }

    private func export(
        defaults: [String: Any] = [:], folder: String? = "/Volumes/Music", excluding: Set<String> = []
    ) throws -> LibraryHandoffManifest {
        try LibraryHandoff.export(
            dataFolder: legacyData, defaults: defaults, libraryFolderPath: folder, appVersion: "1.9",
            into: group, excluding: excluding, now: exportedAt
        )
    }

    func testTheLibraryRoundTripsBetweenTwoContainers() throws {
        let database: [UInt8] = (0..<4096).map { UInt8($0 % 251) }
        try write("library.sqlite", in: legacyData, bytes: database)
        try write("library.sqlite-wal", in: legacyData, bytes: [1, 2, 3])
        try write("Equalizer/state.json", in: legacyData, bytes: [9, 9])
        try write("Covers/a/cover.jpg", in: legacyData, bytes: [5, 6, 7])
        _ = try export(defaults: ["flaccy.mac.volume": 0.5, "flaccy.mac.songsSource": "all"])

        let outcome = try LibraryHandoff.importExport(from: group, into: universalData)

        guard case .imported(let manifest, let defaults) = outcome else { return XCTFail("nothing was imported") }
        XCTAssertEqual(try Data(contentsOf: universalData.appendingPathComponent("library.sqlite")), Data(database))
        XCTAssertEqual(try Data(contentsOf: universalData.appendingPathComponent("library.sqlite-wal")), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: universalData.appendingPathComponent("Equalizer/state.json")), Data([9, 9]))
        XCTAssertEqual(try Data(contentsOf: universalData.appendingPathComponent("Covers/a/cover.jpg")), Data([5, 6, 7]))
        XCTAssertEqual(defaults["flaccy.mac.volume"] as? Double, 0.5)
        XCTAssertEqual(defaults["flaccy.mac.songsSource"] as? String, "all")
        XCTAssertEqual(manifest, LibraryHandoffManifest(exportedAt: exportedAt, appVersion: "1.9", libraryFolderPath: "/Volumes/Music"))
    }

    func testTheManifestKeepsTheLibraryFolderPathAsAPlainString() throws {
        try write("library.sqlite", in: legacyData, bytes: [1])
        _ = try export(folder: "/Users/someone/Music/FLAC Albums")

        let manifest = try XCTUnwrap(LibraryHandoff.manifest(in: group))

        XCTAssertEqual(manifest.libraryFolderPath, "/Users/someone/Music/FLAC Albums")
        let raw = try String(contentsOf: LibraryHandoff.exportFolder(in: group).appendingPathComponent("manifest.json"), encoding: .utf8)
        XCTAssertTrue(raw.contains("\"/Users/someone/Music/FLAC Albums\""))
    }

    func testTheLegacyDataFolderIsNeverChanged() throws {
        let database = try write("library.sqlite", in: legacyData, bytes: [4, 5, 6])
        _ = try export()

        XCTAssertEqual(try Data(contentsOf: database), Data([4, 5, 6]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyData.path))
    }

    func testAnExistingDatabaseIsNeverReplaced() throws {
        try write("library.sqlite", in: legacyData, bytes: [1, 1, 1])
        _ = try export(defaults: ["flaccy.mac.volume": 0.1])
        try write("library.sqlite", in: universalData, bytes: [8, 8])

        let outcome = try LibraryHandoff.importExport(from: group, into: universalData)

        guard case .databaseExists = outcome else { return XCTFail("expected the existing database to win, got \(outcome)") }
        XCTAssertEqual(try Data(contentsOf: universalData.appendingPathComponent("library.sqlite")), Data([8, 8]))
    }

    func testAHalfWrittenExportIsNeverRead() throws {
        try write("library.sqlite", in: legacyData, bytes: [1, 2])
        let staging = group.appendingPathComponent("Handoff.tmp-\(UUID().uuidString)/Application Support/flaccy")
        try write("library.sqlite", in: staging, bytes: [1, 2])

        XCTAssertNil(LibraryHandoff.manifest(in: group))
        guard case .noExport = try LibraryHandoff.importExport(from: group, into: universalData) else {
            return XCTFail("a staging folder was read")
        }

        let unfinished = LibraryHandoff.exportFolder(in: group)
        try write("Application Support/flaccy/library.sqlite", in: unfinished, bytes: [1, 2])
        guard case .noExport = try LibraryHandoff.importExport(from: group, into: universalData) else {
            return XCTFail("an export without a manifest was read")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: universalData.appendingPathComponent("library.sqlite").path))
    }

    func testAnUnreadableManifestIsNotAnExport() throws {
        let unfinished = LibraryHandoff.exportFolder(in: group)
        try write("Application Support/flaccy/library.sqlite", in: unfinished, bytes: [1])
        try write("manifest.json", in: unfinished, bytes: Array("{ \"exportedAt\": ".utf8))

        guard case .noExport = try LibraryHandoff.importExport(from: group, into: universalData) else {
            return XCTFail("a truncated manifest was read")
        }
    }

    func testTheNewestExportWinsAndLeavesNoStagingFolder() throws {
        try write("library.sqlite", in: legacyData, bytes: [1])
        _ = try export()
        try write("library.sqlite", in: legacyData, bytes: [2, 2])
        try write("Covers/new.jpg", in: legacyData, bytes: [3])
        _ = try export()

        guard case .imported = try LibraryHandoff.importExport(from: group, into: universalData) else {
            return XCTFail("nothing was imported")
        }
        XCTAssertEqual(try Data(contentsOf: universalData.appendingPathComponent("library.sqlite")), Data([2, 2]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: universalData.appendingPathComponent("Covers/new.jpg").path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: group.path)
        XCTAssertEqual(leftovers, ["Handoff"])
    }

    func testAnUnchangedFileIsNotCopiedAgain() throws {
        let song = try write("Music/a.flac", in: legacyData, bytes: [7, 7, 7, 7])
        _ = try export()
        let first = LibraryHandoff.exportFolder(in: group).appendingPathComponent("Application Support/flaccy/Music/a.flac")
        let firstNode = try FileManager.default.attributesOfItem(atPath: first.path)[.systemFileNumber] as? UInt64

        _ = try export()
        let second = LibraryHandoff.exportFolder(in: group).appendingPathComponent("Application Support/flaccy/Music/a.flac")
        let secondNode = try FileManager.default.attributesOfItem(atPath: second.path)[.systemFileNumber] as? UInt64

        XCTAssertNotNil(firstNode)
        XCTAssertEqual(firstNode, secondNode)
        XCTAssertEqual(try Data(contentsOf: second), try Data(contentsOf: song))
    }

    func testAChangedFileIsCopiedAgain() throws {
        let song = try write("Music/a.flac", in: legacyData, bytes: [7, 7, 7, 7])
        _ = try export()
        try Data([8, 8, 8, 8]).write(to: song)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: song.path)
        _ = try export()

        let exported = LibraryHandoff.exportFolder(in: group).appendingPathComponent("Application Support/flaccy/Music/a.flac")
        XCTAssertEqual(try Data(contentsOf: exported), Data([8, 8, 8, 8]))
    }

    func testExcludedFoldersStayOut() throws {
        try write("library.sqlite", in: legacyData, bytes: [1])
        try write("Music/a.flac", in: legacyData, bytes: [7])
        _ = try export(excluding: ["Music"])

        guard case .imported = try LibraryHandoff.importExport(from: group, into: universalData) else {
            return XCTFail("nothing was imported")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: universalData.appendingPathComponent("Music/a.flac").path))
    }

    func testTheDatabaseSnapshotReplacesTheFileCopy() throws {
        try write("library.sqlite", in: legacyData, bytes: [1, 1])
        try write("library.sqlite-wal", in: legacyData, bytes: [2, 2])
        _ = try LibraryHandoff.export(
            dataFolder: legacyData, defaults: [:], libraryFolderPath: nil, appVersion: "1.9", into: group,
            writeDatabase: { try Data([9, 9, 9]).write(to: $0) }, now: exportedAt
        )

        guard case .imported = try LibraryHandoff.importExport(from: group, into: universalData) else {
            return XCTFail("nothing was imported")
        }
        XCTAssertEqual(try Data(contentsOf: universalData.appendingPathComponent("library.sqlite")), Data([9, 9, 9]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: universalData.appendingPathComponent("library.sqlite-wal").path))
    }

    func testFilesAlreadyInTheNewContainerAreKept() throws {
        try write("library.sqlite", in: legacyData, bytes: [1])
        try write("Equalizer/state.json", in: legacyData, bytes: [1])
        _ = try export()
        try write("Equalizer/state.json", in: universalData, bytes: [5])

        guard case .imported = try LibraryHandoff.importExport(from: group, into: universalData) else {
            return XCTFail("nothing was imported")
        }
        XCTAssertEqual(try Data(contentsOf: universalData.appendingPathComponent("Equalizer/state.json")), Data([5]))
    }

    private func isFreshDatabase(_ url: URL) -> Bool {
        (try? Data(contentsOf: url)) == Data([0])
    }

    private var stagingFolders: [String] {
        let parent = universalData.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        return names.filter { $0.contains(".handoff-import-") }
    }

    func testAFailedImportLeavesNothingBehindAndTheNextLaunchImportsAgain() throws {
        let database: [UInt8] = (0..<512).map { UInt8($0 % 200) + 1 }
        try write("library.sqlite", in: legacyData, bytes: database)
        try write("Covers/a/cover.jpg", in: legacyData, bytes: [5, 6, 7])
        let unreadable = try write("Covers/b/cover.jpg", in: legacyData, bytes: [8])
        _ = try export(defaults: ["flaccy.mac.volume": 0.5])
        let exportedUnreadable = LibraryHandoff.exportFolder(in: group)
            .appendingPathComponent("Application Support/flaccy/Covers/b/cover.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unreadable.path))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: exportedUnreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: exportedUnreadable.path) }

        XCTAssertThrowsError(try LibraryHandoff.importExport(from: group, into: universalData, libraryIsEmpty: isFreshDatabase))

        XCTAssertFalse(FileManager.default.fileExists(atPath: universalData.appendingPathComponent("library.sqlite").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: universalData.appendingPathComponent("Covers").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: LibraryHandoff.completionMarker(in: universalData).path))
        XCTAssertEqual(stagingFolders, [])

        try write("library.sqlite", in: universalData, bytes: [0])
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: exportedUnreadable.path)

        let retried = try LibraryHandoff.importExport(from: group, into: universalData, libraryIsEmpty: isFreshDatabase)

        guard case .imported(_, let defaults) = retried else { return XCTFail("the retry did not import, got \(retried)") }
        XCTAssertEqual(defaults["flaccy.mac.volume"] as? Double, 0.5)
        XCTAssertEqual(try Data(contentsOf: universalData.appendingPathComponent("library.sqlite")), Data(database))
        XCTAssertEqual(try Data(contentsOf: universalData.appendingPathComponent("Covers/b/cover.jpg")), Data([8]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: LibraryHandoff.completionMarker(in: universalData).path))
        XCTAssertEqual(stagingFolders, [])

        guard case .databaseExists = try LibraryHandoff.importExport(from: group, into: universalData, libraryIsEmpty: isFreshDatabase) else {
            return XCTFail("a completed import ran again")
        }
    }

    func testAnEmptyLibraryAfterACompletedImportIsNotImportedAgain() throws {
        try write("library.sqlite", in: legacyData, bytes: [1, 2, 3])
        _ = try export()
        guard case .imported = try LibraryHandoff.importExport(from: group, into: universalData, libraryIsEmpty: isFreshDatabase) else {
            return XCTFail("nothing was imported")
        }
        try write("library.sqlite", in: universalData, bytes: [0])

        guard case .databaseExists = try LibraryHandoff.importExport(from: group, into: universalData, libraryIsEmpty: isFreshDatabase) else {
            return XCTFail("an emptied library was replaced by the old export")
        }
        XCTAssertEqual(try Data(contentsOf: universalData.appendingPathComponent("library.sqlite")), Data([0]))
    }

    func testALibraryWithTracksIsLeftAloneAndCounted() throws {
        try write("library.sqlite", in: legacyData, bytes: [1, 2, 3])
        _ = try export()
        try write("library.sqlite", in: universalData, bytes: [4, 4])

        guard case .databaseExists = try LibraryHandoff.importExport(from: group, into: universalData, libraryIsEmpty: isFreshDatabase) else {
            return XCTFail("a library with tracks was replaced")
        }
        XCTAssertEqual(try Data(contentsOf: universalData.appendingPathComponent("library.sqlite")), Data([4, 4]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: LibraryHandoff.completionMarker(in: universalData).path))
    }

    func testAnEmptyDatabaseAndItsWriteAheadFilesAreReplacedOnRetry() throws {
        try write("library.sqlite", in: legacyData, bytes: [1, 2, 3])
        _ = try export()
        try write("library.sqlite", in: universalData, bytes: [0])
        try write("library.sqlite-wal", in: universalData, bytes: [9, 9])
        try write("library.sqlite-shm", in: universalData, bytes: [9])

        guard case .imported = try LibraryHandoff.importExport(from: group, into: universalData, libraryIsEmpty: isFreshDatabase) else {
            return XCTFail("the empty database blocked the import")
        }
        XCTAssertEqual(try Data(contentsOf: universalData.appendingPathComponent("library.sqlite")), Data([1, 2, 3]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: universalData.appendingPathComponent("library.sqlite-wal").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: universalData.appendingPathComponent("library.sqlite-shm").path))
    }

    func testAMissingDataFolderIsCreatedInOneMove() throws {
        try write("library.sqlite", in: legacyData, bytes: [1, 2, 3])
        _ = try export()
        try FileManager.default.removeItem(at: universalData)

        guard case .imported = try LibraryHandoff.importExport(from: group, into: universalData) else {
            return XCTFail("nothing was imported")
        }
        XCTAssertEqual(try Data(contentsOf: universalData.appendingPathComponent("library.sqlite")), Data([1, 2, 3]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: LibraryHandoff.completionMarker(in: universalData).path))
    }

    func testOnlyTheAppsOwnDefaultsAreExported() {
        let owned = LibraryHandoff.ownedDefaults([
            "flaccy.mac.volume": 0.5,
            "AppleLanguages": ["en"],
            "NSWindow Frame main": "0 0 1 1",
            "com.apple.finder.x": 1,
            "flaccy.mac.libraryBookmark": Data([1, 2]),
        ])

        XCTAssertEqual(Set(owned.keys), ["flaccy.mac.volume", "flaccy.mac.libraryBookmark"])
    }

    func testNoExportMeansNothingToImport() throws {
        guard case .noExport = try LibraryHandoff.importExport(from: group, into: universalData) else {
            return XCTFail("an empty group container held an export")
        }
    }
}
