import XCTest
@testable import FlaccyCore

#if canImport(AVFoundation)
final class LibraryScannerTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flaccy-scanner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testTheLastSnapshotClosesTheLoadOutAtAHundredPercent() async throws {
        try Data("not audio".utf8).write(to: directory.appendingPathComponent("readme.txt"))

        let reported = Reported()
        _ = await LibraryScanner.scan(directory: directory) { reported.append($0) }

        let last = try XCTUnwrap(reported.snapshots.last)
        XCTAssertEqual(last.phase, .buildingAlbums)
        XCTAssertTrue(last.isDeterminate)
        XCTAssertEqual(last.fractionCompleted, 1.0, accuracy: 0.0001)
    }

    func testEveryPhaseIsReportedInOrder() async {
        let reported = Reported()
        _ = await LibraryScanner.scan(directory: directory) { reported.append($0) }

        let phases = reported.snapshots.map(\.phase)
        XCTAssertEqual(phases.first, .findingFiles)
        XCTAssertEqual(phases, phases.sorted())
    }
}

/// Collects the scan's snapshots from whichever task published them.
private final class Reported: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [LibraryLoadProgress] = []

    var snapshots: [LibraryLoadProgress] { lock.withLock { stored } }

    func append(_ progress: LibraryLoadProgress) {
        lock.withLock { stored.append(progress) }
    }
}
#endif
