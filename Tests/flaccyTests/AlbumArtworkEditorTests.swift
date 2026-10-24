import CoreGraphics
import FlaccyCore
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import flaccy

/// The cover editor's pure parts: which keys a cover is stored under, how a
/// framing becomes the saved JPEG, how three catalogs' answers are parsed and
/// ranked, and which images beside a release's music are offered.
nonisolated final class AlbumArtworkEditorTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flaccy-artwork-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testKeysCoverTheAlbumAndEveryTrackOnceSkippingEmptyTitles() {
        let album = makeAlbum(title: "Score", artist: "Various Artists", tracks: [
            makeTrack("a.flac", artist: "Composer A", album: "Score"),
            makeTrack("b.flac", artist: "Composer B", album: "Score"),
            makeTrack("c.flac", artist: "Composer A", album: "Score"),
            makeTrack("d.flac", artist: "Composer C", album: ""),
        ])
        let keys = AlbumArtworkEditor.keys(for: album).map { "\($0.title)|\($0.artist)" }
        XCTAssertEqual(keys, ["Score|Various Artists", "Score|Composer A", "Score|Composer B"])
    }

    func testRenderedSquareHasTheRequestedSizeAndTheSourcesOrientation() throws {
        let source = makeQuadrantImage(width: 1200, height: 900)
        let framing = try XCTUnwrap(ArtworkFraming(imageWidth: 1200, imageHeight: 900, frameSide: 400))
        let data = try XCTUnwrap(AlbumArtworkEditor.render(source, framing: framing))
        let output = try XCTUnwrap(decode(data))

        XCTAssertEqual(output.width, framing.outputPixels(limit: 1600))
        XCTAssertEqual(output.width, output.height)
        let side = output.width
        assertColor(output, x: side / 4, y: side / 4, equals: .red)
        assertColor(output, x: side * 3 / 4, y: side / 4, equals: .green)
        assertColor(output, x: side / 4, y: side * 3 / 4, equals: .blue)
        assertColor(output, x: side * 3 / 4, y: side * 3 / 4, equals: .yellow)
    }

    func testRenderFollowsAZoomedAndPannedFraming() throws {
        let source = makeQuadrantImage(width: 1200, height: 900)
        var framing = try XCTUnwrap(ArtworkFraming(imageWidth: 1200, imageHeight: 900, frameSide: 400))
        framing = framing.zoomed(to: framing.fillZoom * 3).panned(dx: -1000, dy: -1000)
        let output = try XCTUnwrap(decode(try XCTUnwrap(AlbumArtworkEditor.render(source, framing: framing))))

        XCTAssertEqual(output.width, framing.outputPixels(limit: 1600))
        assertColor(output, x: output.width / 2, y: output.height / 2, equals: .yellow)
    }

    func testRenderNeverExceedsTheOutputLimit() throws {
        let source = makeQuadrantImage(width: 3200, height: 3200)
        let framing = try XCTUnwrap(ArtworkFraming(imageWidth: 3200, imageHeight: 3200, frameSide: 400))
        let output = try XCTUnwrap(decode(try XCTUnwrap(AlbumArtworkEditor.render(source, framing: framing))))
        XCTAssertEqual(output.width, 1600)
    }

    func testAppleResultsAskForTheLargestArtAndScoreAnEditionFoldedMatch() throws {
        let json = """
        {"results":[{"collectionId":7,"collectionName":"Kind of Blue (Legacy Edition)","artistName":"Miles Davis",
        "artworkUrl100":"https://is1.example/image/100x100bb.jpg"},{"collectionId":8,"collectionName":"No Art","artistName":"X"}]}
        """
        let candidates = OnlineArtworkSearch.appleCandidates(
            from: Data(json.utf8), title: "Kind of Blue", artist: "Miles Davis"
        )
        let only = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(only.id, "apple-7")
        XCTAssertEqual(only.source, "Apple Music")
        XCTAssertEqual(only.fullURL.absoluteString, "https://is1.example/image/3000x3000bb.jpg")
        XCTAssertEqual(only.thumbnailURL.absoluteString, "https://is1.example/image/360x360bb.jpg")
        XCTAssertEqual(only.score, 1.0, accuracy: 0.0001)
    }

    func testDeezerResultsPreferTheExtraLargeCover() throws {
        let json = """
        {"data":[{"id":3,"title":"Aurorae","artist":{"name":"Kestrel Vale"},"cover_medium":"https://d.example/m.jpg",
        "cover_big":"https://d.example/b.jpg","cover_xl":"https://d.example/xl.jpg"},
        {"id":4,"title":"Bare","artist":null,"cover_medium":"https://d.example/m2.jpg","cover_big":"https://d.example/b2.jpg"}]}
        """
        let candidates = OnlineArtworkSearch.deezerCandidates(from: Data(json.utf8), title: "Aurorae", artist: "Kestrel Vale")
        XCTAssertEqual(candidates.map(\.fullURL.absoluteString), ["https://d.example/xl.jpg", "https://d.example/b2.jpg"])
        XCTAssertEqual(candidates.map(\.thumbnailURL.absoluteString), ["https://d.example/m.jpg", "https://d.example/m2.jpg"])
        XCTAssertEqual(candidates[0].score, 1.0, accuracy: 0.0001)
    }

    func testCoverArtArchiveResultsComeFromReleaseGroupsAtTwoSizes() throws {
        let json = """
        {"release-groups":[{"id":"abc-123","title":"OK Computer","artist-credit":[{"name":"Radiohead","joinphrase":"",
        "artist":{"name":"Radiohead"}}]},{"id":"def-456","title":"Split","artist-credit":[{"name":"A","joinphrase":" & "},{"name":"B"}]}]}
        """
        let candidates = OnlineArtworkSearch.coverArchiveCandidates(
            from: Data(json.utf8), title: "OK Computer", artist: "Radiohead"
        )
        XCTAssertEqual(candidates.map(\.id), ["caa-abc-123", "caa-def-456"])
        XCTAssertEqual(candidates[0].thumbnailURL.absoluteString, "https://coverartarchive.org/release-group/abc-123/front-250")
        XCTAssertEqual(candidates[0].fullURL.absoluteString, "https://coverartarchive.org/release-group/abc-123/front-1200")
        XCTAssertEqual(candidates[0].source, "Cover Art Archive")
        XCTAssertEqual(candidates[1].artist, "A & B")
        XCTAssertEqual(candidates[0].score, 1.0, accuracy: 0.0001)
    }

    func testScoreWeighsTitleThenArtist() {
        let exact = OnlineArtworkSearch.score(candidateTitle: "Album", candidateArtist: "Artist", title: "Album", artist: "Artist")
        let contains = OnlineArtworkSearch.score(candidateTitle: "Album Deluxe Live", candidateArtist: "Artist", title: "Album", artist: "Artist")
        let wrongArtist = OnlineArtworkSearch.score(candidateTitle: "Album", candidateArtist: "Other", title: "Album", artist: "Artist")
        let noCredit = OnlineArtworkSearch.score(candidateTitle: "Album", candidateArtist: "Anyone", title: "Album", artist: "")
        XCTAssertEqual(exact, 1.0, accuracy: 0.0001)
        XCTAssertEqual(contains, 0.7, accuracy: 0.0001)
        XCTAssertEqual(wrongArtist, 0.7, accuracy: 0.0001)
        XCTAssertEqual(noCredit, 0.85, accuracy: 0.0001)
    }

    func testRankDedupesByFullURLSortsByScoreAndCapsTheShelf() {
        var merged = (0..<25).map { candidate(index: $0, score: 0.9 - Double($0) * 0.01) }
        merged.append(candidate(index: 0, score: 0.1))
        let ranked = OnlineArtworkSearch.rank(merged, keepOnlyConfident: false)
        XCTAssertEqual(ranked.count, 18)
        XCTAssertEqual(ranked.first?.id, "c0")
        XCTAssertEqual(ranked.map(\.score), ranked.map(\.score).sorted(by: >))
    }

    func testRankDropsWeakMatchesOnlyWhenThereAreEnoughConfidentOnes() {
        let strong = (0..<3).map { candidate(index: $0, score: 0.8) }
        let weak = (3..<6).map { candidate(index: $0, score: 0.2) }
        XCTAssertEqual(OnlineArtworkSearch.rank(strong + weak, keepOnlyConfident: true).count, 3)
        XCTAssertEqual(OnlineArtworkSearch.rank(strong + weak, keepOnlyConfident: false).count, 6)
        XCTAssertEqual(OnlineArtworkSearch.rank(Array(strong.prefix(2)) + weak, keepOnlyConfident: true).count, 5)
    }

    func testTheDefaultQueryLeavesOutAVariousArtistsCredit() {
        XCTAssertEqual(OnlineArtworkSearch.defaultQuery(title: "Score", artist: "Various Artists"), "Score")
        XCTAssertEqual(OnlineArtworkSearch.defaultQuery(title: "Aurorae", artist: "Kestrel Vale"), "Kestrel Vale Aurorae")
    }

    func testTheMusicBrainzQueryEscapesQuotesAndBackslashes() {
        XCTAssertEqual(
            OnlineArtworkSearch.musicBrainzQuery(title: "Say \"Hi\"", artist: "A\\B"),
            "releasegroup:\"Say \\\"Hi\\\"\" AND artist:\"A\\\\B\""
        )
        XCTAssertEqual(OnlineArtworkSearch.musicBrainzQuery(title: "Score", artist: ""), "releasegroup:\"Score\"")
    }

    func testFolderImagesAreRankedBySpellingAndSkipTheRest() throws {
        let album = directory.appendingPathComponent("Artist/Album", isDirectory: true)
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        for name in ["back.jpg", "booklet.png", "cover.jpg", "folder.png", "scan.jpg", "thumb.jpg", "AlbumArtSmall.jpg", "._cover.jpg"] {
            try writeImage(to: album.appendingPathComponent(name), width: 640, height: 480)
        }
        try Data("notes".utf8).write(to: album.appendingPathComponent("notes.txt"))
        try Data(count: ArtworkLocalRules.maximumFileBytes + 1).write(to: album.appendingPathComponent("huge.jpg"))
        let tracks = [
            makeTrack("Artist/Album/01.flac", artist: "Artist", album: "Album", under: directory),
            makeTrack("Artist/Album/02.flac", artist: "Artist", album: "Album", under: directory),
        ]

        let items = LocalArtworkFinder.folderImages(
            for: makeAlbum(title: "Album", artist: "Artist", tracks: tracks), root: directory
        )
        XCTAssertEqual(items.map(\.label), ["cover.jpg", "folder.png", "scan.jpg", "back.jpg", "booklet.png"])
        XCTAssertEqual(items.first?.pixelWidth, 640)
        XCTAssertEqual(items.first?.pixelHeight, 480)
        XCTAssertNotNil(items.first?.thumbnail)
        XCTAssertGreaterThan(try XCTUnwrap(items.first?.loadData().count), 0)
    }

    func testFolderImagesIgnoreAnImageAtTheLibraryRoot() throws {
        try writeImage(to: directory.appendingPathComponent("cover.jpg"), width: 100, height: 100)
        let track = makeTrack("loose.flac", artist: "Artist", album: "Album", under: directory)
        let items = LocalArtworkFinder.folderImages(
            for: makeAlbum(title: "Album", artist: "Artist", tracks: [track]), root: directory
        )
        XCTAssertTrue(items.isEmpty)
    }

    func testTracksOutsideTheRootAreNotSearched() {
        let outside = makeTrack("elsewhere.flac", artist: "Artist", album: "Album", under: URL(fileURLWithPath: "/nonexistent-root"))
        XCTAssertTrue(LocalArtworkFinder.relativePaths(of: [outside.fileURL], under: directory).isEmpty)
    }

    func testContentHashSeparatesDifferentBytesAndMatchesEqualOnes() {
        XCTAssertEqual(LocalArtworkFinder.contentHash(of: Data([1, 2, 3])), LocalArtworkFinder.contentHash(of: Data([1, 2, 3])))
        XCTAssertNotEqual(LocalArtworkFinder.contentHash(of: Data([1, 2, 3])), LocalArtworkFinder.contentHash(of: Data([1, 2, 4])))
    }

    private func candidate(index: Int, score: Double) -> ArtworkCandidate {
        ArtworkCandidate(
            id: "c\(index)", source: "Test", title: "t", artist: "a",
            thumbnailURL: URL(string: "https://x.example/t\(index).jpg")!,
            fullURL: URL(string: "https://x.example/f\(index).jpg")!,
            score: score
        )
    }

    private func makeTrack(_ relativePath: String, artist: String, album: String, under root: URL = URL(fileURLWithPath: "/lib")) -> Track {
        Track(
            fileURL: root.appendingPathComponent(relativePath), title: relativePath, artist: artist, albumTitle: album,
            albumArtist: nil, trackNumber: 1, duration: 100, artwork: nil, dbID: nil
        )
    }

    private func makeAlbum(title: String, artist: String, tracks: [Track]) -> Album {
        Album(title: title, artist: artist, artwork: nil, tracks: tracks, year: nil, genre: nil)
    }

    private enum Swatch {
        case red, green, blue, yellow

        var components: (UInt8, UInt8, UInt8) {
            switch self {
            case .red: (230, 30, 30)
            case .green: (30, 200, 30)
            case .blue: (30, 30, 230)
            case .yellow: (240, 220, 30)
            }
        }
    }

    private func makeQuadrantImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        let quadrants: [(Swatch, CGRect)] = [
            (.red, CGRect(x: 0, y: height / 2, width: width / 2, height: height - height / 2)),
            (.green, CGRect(x: width / 2, y: height / 2, width: width - width / 2, height: height - height / 2)),
            (.blue, CGRect(x: 0, y: 0, width: width / 2, height: height / 2)),
            (.yellow, CGRect(x: width / 2, y: 0, width: width - width / 2, height: height / 2)),
        ]
        for (swatch, rect) in quadrants {
            let (r, g, b) = swatch.components
            context.setFillColor(CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1))
            context.fill(rect)
        }
        return context.makeImage()!
    }

    private func writeImage(to url: URL, width: Int, height: Int) throws {
        let image = makeQuadrantImage(width: width, height: height)
        let type = url.pathExtension.lowercased() == "png" ? UTType.png : UTType.jpeg
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func decode(_ data: Data) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    private func assertColor(_ image: CGImage, x: Int, y: Int, equals swatch: Swatch, file: StaticString = #filePath, line: UInt = #line) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        let (r, g, b) = swatch.components
        for (got, want) in zip(pixel.prefix(3), [r, g, b]) {
            XCTAssertLessThan(abs(Int(got) - Int(want)), 24, "pixel (\(x), \(y)) is \(pixel.prefix(3))", file: file, line: line)
        }
    }
}
