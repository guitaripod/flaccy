import XCTest
@testable import FlaccyCore

/// Mirrored by the tests in `linux/shared/src/import_plan.rs`: same trees,
/// same placements.
final class ImportPlanTests: XCTestCase {

    private var sandbox: URL!
    private var outside: URL!
    private var library: URL!
    private let audio: Set<String> = ["flac", "mp3"]

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("flaccy-import-\(UUID().uuidString)", isDirectory: true)
        outside = sandbox.appendingPathComponent("outside", isDirectory: true)
        library = sandbox.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    @discardableResult
    private func write(_ path: String, in base: URL, bytes: Int = 4) throws -> URL {
        let url = base.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    private func plan(_ picked: [URL]) -> ImportPlan.Plan {
        ImportPlan.plan(picked: picked, libraryRoot: library, audioExtensions: audio)
    }

    private func destinations(_ plan: ImportPlan.Plan) -> [String] {
        plan.items.map(\.destination)
    }

    func testAPickedFileLandsAtTheTopUnderItsOwnName() throws {
        let file = try write("Downloads/song.flac", in: outside)

        let plan = plan([file])

        XCTAssertEqual(destinations(plan), ["song.flac"])
        XCTAssertEqual(plan.items.first?.kind, .audio)
        XCTAssertEqual(plan.items.first?.size, 4)
    }

    func testAPickedFolderKeepsItsNameAndItsTree() throws {
        try write("Score/CD1/01.flac", in: outside)
        try write("Score/CD2/01.flac", in: outside)

        let plan = plan([outside.appendingPathComponent("Score")])

        XCTAssertEqual(destinations(plan), ["Score/CD1/01.flac", "Score/CD2/01.flac"])
    }

    func testOnlyMusicAndItsLyricsTravel() throws {
        for name in ["song.flac", "song.LRC", "song.elrc", "cover.jpg", "notes.txt", ".hidden.flac", ".DS_Store"] {
            try write("Album/\(name)", in: outside)
        }

        let plan = plan([outside.appendingPathComponent("Album")])

        XCTAssertEqual(destinations(plan), ["Album/song.LRC", "Album/song.elrc", "Album/song.flac"])
        XCTAssertEqual(plan.items.map(\.kind), [.lyrics, .lyrics, .audio])
    }

    func testHiddenFoldersAreNotWalked() throws {
        try write("Album/.git/objects/a.flac", in: outside)
        try write("Album/b.flac", in: outside)

        XCTAssertEqual(destinations(plan([outside.appendingPathComponent("Album")])), ["Album/b.flac"])
    }

    func testALyricsFilePickedOnItsOwnIsNotImported() throws {
        let lyrics = try write("song.lrc", in: outside)

        XCTAssertEqual(plan([lyrics]).items, [])
    }

    func testMusicAlreadyInsideTheLibraryIsCountedNotCopied() throws {
        try write("Artist/Album/01.flac", in: library)
        try write("Artist/Album/02.mp3", in: library)
        try write("Artist/Album/02.lrc", in: library)

        let plan = plan([library.appendingPathComponent("Artist")])

        XCTAssertEqual(plan.items, [])
        XCTAssertEqual(plan.alreadyInLibrary, 2)
    }

    func testTheSameFileAtTheSamePathIsAlreadyPresent() throws {
        try write("Album/01.flac", in: outside)
        try write("Album/01.flac", in: library)

        let placed = ImportPlan.placements(for: plan([outside.appendingPathComponent("Album")]), in: library)

        XCTAssertEqual(placed.map(\.placement), [.alreadyPresent])
    }

    func testADifferentFileUnderATakenNameGetsTheNextFreeName() throws {
        try write("Album/01.flac", in: outside, bytes: 9)
        try write("Album/01.flac", in: library, bytes: 4)

        let placed = ImportPlan.placements(for: plan([outside.appendingPathComponent("Album")]), in: library)

        XCTAssertEqual(placed.map(\.placement), [.copy(to: "Album/01_1.flac")])
    }

    func testImportingTheSameFolderTwiceNeverBreedsASecondCopy() throws {
        try write("Album/01.flac", in: outside, bytes: 9)
        try write("Album/01.flac", in: library, bytes: 4)
        try write("Album/01_1.flac", in: library, bytes: 9)

        let placed = ImportPlan.placements(for: plan([outside.appendingPathComponent("Album")]), in: library)

        XCTAssertEqual(placed.map(\.placement), [.alreadyPresent])
    }

    func testTwoPickedFilesThatShareANameDoNotLandOnEachOther() throws {
        let first = try write("a/x.flac", in: outside, bytes: 4)
        let second = try write("b/x.flac", in: outside, bytes: 9)
        let twin = try write("c/x.flac", in: outside, bytes: 4)

        let placed = ImportPlan.placements(for: plan([first, second, twin]), in: library)

        XCTAssertEqual(placed.map(\.placement), [.copy(to: "x.flac"), .copy(to: "x_1.flac"), .alreadyPresent])
    }

    func testAFolderReachedTwiceThroughASymlinkIsWalkedOnce() throws {
        try write("Album/01.flac", in: outside)
        try FileManager.default.createSymbolicLink(
            at: outside.appendingPathComponent("Album/loop"),
            withDestinationURL: outside.appendingPathComponent("Album")
        )

        XCTAssertEqual(destinations(plan([outside.appendingPathComponent("Album")])), ["Album/01.flac"])
    }

    func testAnICloudPlaceholderIsPlannedUnderItsRealNameWithNoKnownSize() throws {
        try write("Album/.02 Song.flac.icloud", in: outside)

        let plan = plan([outside.appendingPathComponent("Album")])

        XCTAssertEqual(destinations(plan), ["Album/02 Song.flac"])
        XCTAssertEqual(plan.items.first?.source.lastPathComponent, "02 Song.flac")
        XCTAssertNil(plan.items.first?.size)
    }

    func testAPlaceholderWhoseNameIsTakenIsTreatedAsPresent() throws {
        try write("Album/.01.flac.icloud", in: outside)
        try write("Album/01.flac", in: library)

        let placed = ImportPlan.placements(for: plan([outside.appendingPathComponent("Album")]), in: library)

        XCTAssertEqual(placed.map(\.placement), [.alreadyPresent])
    }

    func testPlaceholderNamesAreRecognisedExactly() {
        XCTAssertEqual(ImportPlan.materializedName(ofPlaceholder: ".Song.flac.icloud"), "Song.flac")
        XCTAssertNil(ImportPlan.materializedName(ofPlaceholder: "Song.flac.icloud"))
        XCTAssertNil(ImportPlan.materializedName(ofPlaceholder: ".icloud"))
        XCTAssertNil(ImportPlan.materializedName(ofPlaceholder: ".Song.flac"))
    }
}
