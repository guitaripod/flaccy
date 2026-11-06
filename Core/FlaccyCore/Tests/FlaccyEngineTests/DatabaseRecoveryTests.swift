import GRDB
import XCTest
@testable import FlaccyEngine

/// Only a damaged file is moved aside for a fresh library; a file that cannot
/// be reached right now stays exactly where it is. Mirrors the recovery tests
/// in `linux/library/src/db.rs`.
final class DatabaseRecoveryTests: XCTestCase {

    private var directory: URL!
    private var path: String { directory.appendingPathComponent("library.sqlite").path }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flaccy-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        try? FileManager.default.removeItem(at: directory)
    }

    private var asideFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.contains(".corrupt-") }
    }

    func testAHealthyLibraryOpensInPlace() throws {
        _ = try DatabaseManager.openDatabase(at: path)
        _ = try DatabaseManager.openOrRecover(at: path)
        XCTAssertTrue(asideFiles.isEmpty)
    }

    func testADamagedFileIsMovedAsideForAFreshLibrary() throws {
        let garbage = Data(String(repeating: "not a database ", count: 512).utf8)
        try garbage.write(to: URL(fileURLWithPath: path))
        _ = try DatabaseManager.openOrRecover(at: path)
        XCTAssertEqual(asideFiles.count, 1)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(asideFiles[0])), garbage)
    }

    func testALibraryThatCannotBeOpenedIsLeftWhereItIs() throws {
        let queue = try DatabaseManager.openDatabase(at: path)
        try queue.close()
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)

        XCTAssertThrowsError(try DatabaseManager.openOrRecover(at: path))
        XCTAssertTrue(asideFiles.isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
    }

    func testOnlyCorruptionAndNotADatabaseCountAsDamage() {
        XCTAssertTrue(DatabaseManager.isDamaged(DatabaseError(resultCode: .SQLITE_CORRUPT)))
        XCTAssertTrue(DatabaseManager.isDamaged(DatabaseError(resultCode: .SQLITE_NOTADB)))
        for code: ResultCode in [.SQLITE_CANTOPEN, .SQLITE_PERM, .SQLITE_AUTH, .SQLITE_IOERR, .SQLITE_FULL, .SQLITE_BUSY, .SQLITE_READONLY, .SQLITE_ERROR] {
            XCTAssertFalse(DatabaseManager.isDamaged(DatabaseError(resultCode: code)), "\(code)")
        }
        XCTAssertFalse(DatabaseManager.isDamaged(CocoaError(.fileReadNoPermission)))
    }
}
