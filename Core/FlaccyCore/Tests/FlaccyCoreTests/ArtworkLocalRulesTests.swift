import XCTest
@testable import FlaccyCore

final class ArtworkLocalRulesTests: XCTestCase {

    func testL1OnlyImagesAreCandidates() {
        XCTAssertTrue(ArtworkLocalRules.isCandidate(fileName: "cover.JPG"))
        XCTAssertTrue(ArtworkLocalRules.isCandidate(fileName: "Front.webp"))
        XCTAssertFalse(ArtworkLocalRules.isCandidate(fileName: "01 Song.flac"))
        XCTAssertFalse(ArtworkLocalRules.isCandidate(fileName: "cover.tiff"))
        XCTAssertFalse(ArtworkLocalRules.isCandidate(fileName: "cover"))
    }

    func testL2HiddenAndResourceForkFilesAreSkipped() {
        XCTAssertFalse(ArtworkLocalRules.isCandidate(fileName: "._cover.jpg"))
        XCTAssertFalse(ArtworkLocalRules.isCandidate(fileName: ".folder.jpg"))
    }

    func testL3ThumbnailsAreSkipped() {
        XCTAssertFalse(ArtworkLocalRules.isCandidate(fileName: "AlbumArtSmall.jpg"))
        XCTAssertFalse(ArtworkLocalRules.isCandidate(fileName: "AlbumArt_{4F2A}_Small.jpg"))
        XCTAssertFalse(ArtworkLocalRules.isCandidate(fileName: "cover-thumb.jpg"))
        XCTAssertTrue(ArtworkLocalRules.isCandidate(fileName: "AlbumArt_{4F2A}_Large.jpg"))
        XCTAssertTrue(ArtworkLocalRules.isCandidate(fileName: "Smallville Soundtrack.png"))
    }

    func testL4FrontCoverNamesOutrankEverythingInAFixedOrder() {
        let names = ["booklet.jpg", "scan 1.jpg", "front.jpg", "Folder.jpg", "cover.png", "back.jpg", "AlbumArt_{1}_Large.jpg"]
        XCTAssertEqual(
            ArtworkLocalRules.rank(names),
            ["cover.png", "Folder.jpg", "front.jpg", "AlbumArt_{1}_Large.jpg", "scan 1.jpg", "back.jpg", "booklet.jpg"]
        )
    }

    func testL5NamesThatMerelySoundLikeACoverComeBeforeOthers() {
        XCTAssertEqual(
            ArtworkLocalRules.rank(["zebra.jpg", "Album Cover (1999).jpg", "alpha.jpg"]),
            ["Album Cover (1999).jpg", "alpha.jpg", "zebra.jpg"]
        )
    }

    func testL6BackScansAreRecognisedByWordNotBySubstring() {
        XCTAssertEqual(ArtworkLocalRules.rank(["Back Cover.jpg", "acdc.jpg"]), ["acdc.jpg", "Back Cover.jpg"])
        XCTAssertEqual(ArtworkLocalRules.rank(["CD2.jpg", "mine.jpg"]), ["mine.jpg", "CD2.jpg"])
    }

    func testL7RankingIsCappedAndStable() {
        let names = (0..<30).map { "scan \(String(format: "%02d", $0)).jpg" }
        let ranked = ArtworkLocalRules.rank(names.reversed())
        XCTAssertEqual(ranked.count, ArtworkLocalRules.maximumImagesPerFolder)
        XCTAssertEqual(ranked.first, "scan 00.jpg")
    }

    func testL8ASingleFolderIsItsOwnAnswer() {
        XCTAssertEqual(
            ArtworkLocalRules.folders(forRelativePaths: ["Artist/Album/01.flac", "Artist/Album/02.flac"]),
            ["Artist/Album"]
        )
    }

    func testL9DiscFoldersAreSearchedAfterTheirSharedParent() {
        XCTAssertEqual(
            ArtworkLocalRules.folders(forRelativePaths: ["Artist/Album/CD2/01.flac", "Artist/Album/CD1/01.flac"]),
            ["Artist/Album", "Artist/Album/CD1", "Artist/Album/CD2"]
        )
    }

    func testL10TheLibraryRootIsNeverSearched() {
        XCTAssertEqual(ArtworkLocalRules.folders(forRelativePaths: ["01.flac", "02.flac"]), [])
        XCTAssertEqual(
            ArtworkLocalRules.folders(forRelativePaths: ["A/Album/01.flac", "B/Album/02.flac"]),
            ["A/Album", "B/Album"]
        )
    }

    func testL11ATrackAtTheRootDoesNotHideItsSiblingsFolder() {
        XCTAssertEqual(ArtworkLocalRules.folders(forRelativePaths: ["01.flac", "Album/02.flac"]), ["Album"])
    }
}
