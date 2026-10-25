import AVFoundation
import FlaccyCore
import XCTest
@testable import FlaccyEngine
@testable import flaccy

/// A saved queue that holds songs from a server and files from the library: both kinds are written
/// as the paths their library rows use, come back in the same order from the database, and the
/// shuffle weights see the songs from a server under the URL their tracks carry.
nonisolated final class PlaybackEngineRemoteQueueTests: XCTestCase {

    private static let serverID = "queue-test-server"
    private static let localPath = "Queue Test Artist/Queue Test Album/01 Local.flac"

    private var savedDefaults: [String: Any] = [:]
    private var host: StubHost!

    @MainActor override func setUp() async throws {
        host = StubHost()
        savedDefaults = UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix("flaccy.queue.") }
        clearQueueDefaults()
        try removeFixtureRows()
    }

    @MainActor override func tearDown() async throws {
        try removeFixtureRows()
        clearQueueDefaults()
        for (key, value) in savedDefaults { UserDefaults.standard.set(value, forKey: key) }
    }

    @MainActor func testAQueueOfServerSongsAndLibraryFilesIsSavedAndRestoredInOrder() async throws {
        let database = DatabaseManager.shared
        let tracks = try insertFixtureTracks(database)
        let remoteFirst = tracks[0], local = tracks[1], remoteLast = tracks[2]
        XCTAssertTrue(RemoteTrackPath.isRemote(assetURL: remoteFirst.fileURL))
        XCTAssertFalse(RemoteTrackPath.isRemote(assetURL: local.fileURL))

        let saving = PlaybackEngine()
        saving.host = host
        saving.setQueueForExercise(tracks, currentIndex: 2)
        saving.saveQueueState()

        let expectedPaths = [remotePath("one"), Self.localPath, remotePath("two")]
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: "flaccy.queue.paths"), expectedPaths)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "flaccy.queue.currentPath"), expectedPaths[2])
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "flaccy.queue.index"), 2)

        let restoring = PlaybackEngine()
        restoring.host = host
        restoring.restoreQueueState()
        try await waitUntil { restoring.queue.count == tracks.count }

        XCTAssertEqual(restoring.queue.map(\.fileURL), [remoteFirst.fileURL, local.fileURL, remoteLast.fileURL])
        XCTAssertEqual(restoring.queue.map(\.title), ["Remote One", "Local", "Remote Two"])
        XCTAssertEqual(restoring.currentIndex, 2)
        XCTAssertEqual(restoring.currentTrack?.fileURL, remoteLast.fileURL)
        XCTAssertEqual(restoring.currentTrack?.remoteSong, RemoteTrackPath(serverID: Self.serverID, songID: "two"))
        XCTAssertNil(restoring.queue[1].remoteSong)
    }

    @MainActor func testAShuffledQueueKeepsTheOriginalOrderOfServerSongsToo() async throws {
        let database = DatabaseManager.shared
        let tracks = try insertFixtureTracks(database)

        let saving = PlaybackEngine()
        saving.host = host
        saving.setQueueForExercise(tracks.reversed(), currentIndex: 0, originalQueue: tracks, shuffled: true)
        saving.saveQueueState()

        let expectedOriginal = [remotePath("one"), Self.localPath, remotePath("two")]
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: "flaccy.queue.originalPaths"), expectedOriginal)
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: "flaccy.queue.paths"), expectedOriginal.reversed())

        let restoring = PlaybackEngine()
        restoring.host = host
        restoring.restoreQueueState()
        try await waitUntil { restoring.queue.count == tracks.count }

        XCTAssertEqual(restoring.queue.map(\.fileURL), tracks.reversed().map(\.fileURL))
        XCTAssertEqual(restoring.originalQueue.map(\.fileURL), tracks.map(\.fileURL))
        XCTAssertTrue(restoring.shuffleEnabled)
    }

    @MainActor func testTheShuffleWeightsKeyAServerSongByTheURLItsTrackCarries() throws {
        let database = DatabaseManager.shared
        let tracks = try insertFixtureTracks(database)
        let engine = PlaybackEngine()
        engine.host = host

        let weights = engine.recencyWeights()

        for track in tracks {
            XCTAssertEqual(weights[track.fileURL.standardizedFileURL], 1.0, "\(track.title) has a weight")
        }
    }

    @MainActor private func insertFixtureTracks(_ database: DatabaseManager) throws -> [Track] {
        let local = try database.insertTrack(TrackRecord(
            fileURL: Self.localPath, title: "Local", artist: "Queue Test Artist", albumTitle: "Queue Test Album",
            trackNumber: 1, duration: 100, dateAdded: Date(), playCount: 0, aiAnalyzed: true
        ))
        try database.applyRemoteCatalog(RemoteCatalogChange(
            serverID: Self.serverID,
            inserts: [(songID: "one", facts: facts(title: "Remote One")), (songID: "two", facts: facts(title: "Remote Two"))],
            updates: [], newVersions: [], removedSongIDs: [], now: Date()
        ))
        let first = try XCTUnwrap(database.fetchTrack(byRelativePath: remotePath("one")))
        let last = try XCTUnwrap(database.fetchTrack(byRelativePath: remotePath("two")))
        return [Track.from(record: first, artwork: nil), Track.from(record: local, artwork: nil), Track.from(record: last, artwork: nil)]
    }

    private func facts(title: String) -> RemoteSongFacts {
        RemoteSongFacts(
            title: title, artist: "Queue Test Artist", albumTitle: "Queue Test Album", albumArtist: nil, trackNumber: 1,
            duration: 20, suffix: "flac", size: 1_000, coverArt: nil, albumId: nil, codec: "FLAC", bitDepth: 16,
            sampleRate: 44_100, channels: 2, fingerprint: nil
        )
    }

    private func remotePath(_ songID: String) -> String {
        RemoteTrackPath(serverID: Self.serverID, songID: songID).path
    }

    @MainActor private func removeFixtureRows() throws {
        let database = DatabaseManager.shared
        try database.deleteRemoteServer(id: Self.serverID)
        if let existing = try database.fetchTrack(byRelativePath: Self.localPath)?.id {
            try database.deleteTrack(id: existing)
        }
    }

    @MainActor private func clearQueueDefaults() {
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("flaccy.queue.") {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    }

    private final class StubHost: PlaybackEngineHost {
        var libraryRoot: URL { LibraryPaths.root }
        func isPlaybackGated() -> Bool { false }
        func attachEqualizer(to item: AVPlayerItem) {}
        func remoteAsset(for track: Track) -> AVURLAsset { AVURLAsset(url: track.fileURL) }
        func activateAudioSession() {}
        func playFeedback(_ kind: PlaybackFeedbackKind) {}
        func playbackStateDidUpdate() {}
        func trackDidStart(_ track: Track) {}
        func trackWillBeSkipped() {}
        func trackDidFinishNaturally() {}
        func playbackDidProgress() {}
        func artworkIsNeeded(for track: Track) {}
        func restoredTrack(from record: TrackRecord, artworkByAlbum: inout [String: PlatformImage?]) -> Track {
            Track.from(record: record, artwork: nil)
        }
        func libraryTracks() -> [Track] { [] }
    }
}

extension PlaybackEngine {

    func setQueueForExercise(_ tracks: [Track], currentIndex: Int, originalQueue: [Track]? = nil, shuffled: Bool = false) {
        queue = tracks
        self.originalQueue = originalQueue ?? tracks
        self.currentIndex = currentIndex
        shuffleEnabled = shuffled
    }
}
