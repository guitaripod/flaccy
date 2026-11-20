import XCTest
import FlaccyCore
@testable import flaccy

/// Clean Library's one switch, how it shows an album's page, and the chips that narrow albums to the songs that answer
/// to them.
nonisolated final class CleanLibraryTests: XCTestCase {

    private static let keys = [CleanLibrarySetting.key, "hideDuplicateSongs", "groupAlbumEditions"]
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        saved = Dictionary(uniqueKeysWithValues: Self.keys.compactMap { key in defaults.object(forKey: key).map { (key, $0) } })
        Self.keys.forEach(defaults.removeObject(forKey:))
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        Self.keys.forEach(defaults.removeObject(forKey:))
        saved.forEach { defaults.set($0.value, forKey: $0.key) }
        super.tearDown()
    }

    private func track(_ title: String, album: String = "Night Ferry", number: Int, id: Int64, url: URL? = nil) -> Track {
        Track(
            fileURL: url ?? URL(fileURLWithPath: "/lib/Corvid & Crane/\(album)/\(number) \(title).flac"),
            title: title, artist: "Corvid & Crane", albumTitle: album, albumArtist: nil,
            trackNumber: number, duration: 200, artwork: nil, dbID: id,
            codec: "FLAC", bitDepth: 16, sampleRate: 44_100, channels: 2
        )
    }

    private func serverTrack(_ title: String, number: Int, id: Int64, song: String) -> Track {
        track(title, number: number, id: id, url: RemoteTrackPath(serverID: "home", songID: song).assetURL)
    }

    private func album(_ tracks: [Track], title: String = "Night Ferry") -> Album {
        Album(title: title, artist: "Corvid & Crane", artwork: nil, tracks: tracks, year: "2024", genre: "Folk")
    }

    func testCleanLibraryIsOnByDefault() {
        XCTAssertTrue(CleanLibrarySetting.isEnabled)
    }

    func testCleanLibraryStartsOnOnlyWhenBothOldSettingsWereOn() {
        UserDefaults.standard.set(true, forKey: "hideDuplicateSongs")
        UserDefaults.standard.set(true, forKey: "groupAlbumEditions")
        XCTAssertTrue(CleanLibrarySetting.isEnabled)
        UserDefaults.standard.set(false, forKey: "groupAlbumEditions")
        XCTAssertFalse(CleanLibrarySetting.isEnabled)
        UserDefaults.standard.set(true, forKey: CleanLibrarySetting.key)
        XCTAssertTrue(CleanLibrarySetting.isEnabled)
    }

    func testAnAlbumPageShowsEachSongOnce() {
        let lowTide = track("Low Tide", number: 2, id: 1)
        let file = track("Harbor Lights", number: 3, id: 2)
        let streamed = serverTrack("Harbor Lights", number: 3, id: 3, song: "s3")
        let shown = CleanLibrarySetting.eachSongOnce(in: album([lowTide, file, streamed]))
        XCTAssertEqual(shown.tracks, [lowTide, file])
        XCTAssertEqual(shown.id, "Night Ferry|Corvid & Crane")
        XCTAssertEqual(shown.year, "2024")
    }

    func testAnAlbumPageShowsEveryCopyWhenCleanLibraryIsOff() {
        UserDefaults.standard.set(false, forKey: CleanLibrarySetting.key)
        let tracks = [track("Harbor Lights", number: 3, id: 2), serverTrack("Harbor Lights", number: 3, id: 3, song: "s3")]
        XCTAssertEqual(CleanLibrarySetting.eachSongOnce(in: album(tracks)).tracks, tracks)
    }

    func testNarrowingShowsTheAlbumsPartThatAnswersAndDropsTheRest() {
        let file = track("Low Tide", number: 2, id: 1)
        let streamed = serverTrack("Harbor Lights", number: 3, id: 2, song: "s3")
        let onlyStreamed = serverTrack("Roost", number: 1, id: 3, song: "s9")
        let albums = [album([file, streamed]), album([onlyStreamed], title: "Roost")]
        let narrowed = LibraryViewModel.narrowing(albums) { $0.remoteSong == nil }
        XCTAssertEqual(narrowed.map(\.id), ["Night Ferry|Corvid & Crane"])
        XCTAssertEqual(narrowed.first?.tracks, [file])
        XCTAssertEqual(LibraryViewModel.narrowing(albums) { _ in true }.map(\.tracks), albums.map(\.tracks))
    }

    func testOfflineAdmitsFilesAndLeavesOutServerSongsNotKeptWhole() {
        XCTAssertTrue(LibraryViewModel.playsOffline(track("Low Tide", number: 2, id: 1)))
        XCTAssertFalse(LibraryViewModel.playsOffline(serverTrack("Never Cached", number: 4, id: 2, song: "never-cached")))
    }
}
