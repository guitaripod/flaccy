import AVFoundation
import FlaccyCore
import XCTest
@testable import flaccy

nonisolated final class RemoteCacheFilesTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("flaccy-remote-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testASidecarRoundTripsEveryField() throws {
        var ranges = ByteRangeSet()
        ranges.insert(0..<100)
        ranges.insert(200..<300)
        let sidecar = RemoteCacheSidecar(
            file: "song.flac", total: 1_000, validator: "Sun, 25 Oct 2026 12:48:14 GMT", ranges: ranges,
            lastUsed: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let decoded = try RemoteCacheSidecar.decode(try sidecar.encoded())

        XCTAssertEqual(decoded, sidecar)
        XCTAssertEqual(decoded.ranges.ranges, [0..<100, 200..<300])
        XCTAssertEqual(decoded.lastUsedDate, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertFalse(decoded.isComplete)
    }

    func testASidecarIsCompleteOnlyWhenOneRangeCoversTheWholeFile() {
        var ranges = ByteRangeSet()
        ranges.insert(0..<500)
        var sidecar = RemoteCacheSidecar(file: "a.flac", total: 1_000, ranges: ranges, lastUsed: Date())
        XCTAssertFalse(sidecar.isComplete)
        sidecar.ranges.insert(500..<1_000)
        XCTAssertTrue(sidecar.isComplete)
        sidecar.total = nil
        XCTAssertFalse(sidecar.isComplete)
    }

    func testLayoutPutsCachedAndPinnedFilesUnderTheirServer() {
        let song = RemoteTrackPath(serverID: "srv-1", songID: "a/b c")

        let cached = RemoteCacheLayout.audioURL(in: RemoteCacheLayout.cachesRoot(base: directory), song: song, suffix: "FLAC")
        let pinned = RemoteCacheLayout.sidecarURL(in: RemoteCacheLayout.pinnedRoot(base: directory), song: song)

        XCTAssertEqual(cached.path, directory.appendingPathComponent("Remote/srv-1/a%2Fb%20c.flac").path)
        XCTAssertEqual(pinned.path, directory.appendingPathComponent("Remote/srv-1/a%2Fb%20c.ranges.json").path)
        XCTAssertEqual(RemoteCacheLayout.key(for: song), "srv-1/a%2Fb%20c")
    }

    func testASongWithoutASuffixGetsAGenericExtension() {
        let song = RemoteTrackPath(serverID: "srv", songID: "x")

        XCTAssertEqual(RemoteCacheLayout.audioFileName(for: song, suffix: nil), "x.audio")
        XCTAssertEqual(RemoteCacheLayout.audioFileName(for: song, suffix: "../evil"), "x.evil")
    }

    func testAudioTypesFollowTheSuffix() {
        XCTAssertEqual(RemoteAudioType.identifier(forSuffix: "flac"), "org.xiph.flac")
        XCTAssertEqual(RemoteAudioType.identifier(forSuffix: "MP3"), "public.mp3")
        XCTAssertEqual(RemoteAudioType.identifier(forSuffix: "m4a"), "com.apple.m4a-audio")
        XCTAssertEqual(RemoteAudioType.identifier(forSuffix: "alac"), "com.apple.m4a-audio")
        XCTAssertEqual(RemoteAudioType.identifier(forSuffix: "wav"), "com.microsoft.waveform-audio")
        XCTAssertEqual(RemoteAudioType.identifier(forSuffix: "aiff"), "public.aiff-audio")
        XCTAssertEqual(RemoteAudioType.identifier(forSuffix: nil), "public.audio")
    }

    func testAWholeCachedFileIsFoundAndAPartialOneIsNot() async throws {
        let cache = makeCache()
        let song = RemoteTrackPath(serverID: "srv", songID: "s1")
        let audio = try writeCached(song, bytes: 1_000, coveredUpTo: 600, in: cache)

        XCTAssertNil(cache.completeFileURL(for: song))

        _ = try writeCached(song, bytes: 1_000, coveredUpTo: 1_000, in: cache)
        XCTAssertEqual(cache.completeFileURL(for: song)?.path, audio.path)
        XCTAssertEqual(cache.readableFile(for: song.assetURL)?.path, audio.path)
    }

    func testAFileShorterThanItsSidecarClaimsIsNotComplete() throws {
        let cache = makeCache()
        let song = RemoteTrackPath(serverID: "srv", songID: "s2")
        let audio = try writeCached(song, bytes: 1_000, coveredUpTo: 1_000, in: cache)
        try Data(count: 400).write(to: audio)

        XCTAssertNil(cache.completeFileURL(for: song))
    }

    func testEvictionRemovesTheLeastRecentlyUsedFirstAndSparesProtectedSongs() async throws {
        let cache = makeCache()
        let previous = RemoteStreamCache.capBytes
        RemoteStreamCache.capBytes = 2_500
        defer { RemoteStreamCache.capBytes = previous }
        let old = RemoteTrackPath(serverID: "srv", songID: "old")
        let middle = RemoteTrackPath(serverID: "srv", songID: "middle")
        let recent = RemoteTrackPath(serverID: "srv", songID: "recent")
        try writeCached(old, bytes: 1_000, coveredUpTo: 1_000, in: cache, lastUsed: Date(timeIntervalSince1970: 100))
        try writeCached(middle, bytes: 1_000, coveredUpTo: 1_000, in: cache, lastUsed: Date(timeIntervalSince1970: 200))
        try writeCached(recent, bytes: 1_000, coveredUpTo: 1_000, in: cache, lastUsed: Date(timeIntervalSince1970: 300))
        await cache.protect(current: old, next: nil)

        await cache.evictIfNeeded()

        XCTAssertNotNil(cache.completeFileURL(for: old), "a protected song keeps its file")
        XCTAssertNil(cache.completeFileURL(for: middle), "the next least recently used goes instead")
        XCTAssertNotNil(cache.completeFileURL(for: recent))
    }

    func testPinnedFilesAreNeverEvicted() async throws {
        let cache = makeCache()
        let previous = RemoteStreamCache.capBytes
        RemoteStreamCache.capBytes = 10
        defer { RemoteStreamCache.capBytes = previous }
        let song = RemoteTrackPath(serverID: "srv", songID: "kept")
        try writeCached(song, bytes: 1_000, coveredUpTo: 1_000, in: cache, pinned: true)

        await cache.evictIfNeeded()

        XCTAssertNotNil(cache.completeFileURL(for: song))
    }

    func testRoutingPlaysACompleteFileDirectlyAndStreamsEverythingElse() {
        let song = RemoteTrackPath(serverID: "srv", songID: "s")
        let file = URL(fileURLWithPath: "/tmp/s.flac")

        XCTAssertEqual(RemoteAssetRoute.route(for: song, completeFile: file), .file(file))
        XCTAssertEqual(RemoteAssetRoute.route(for: song, completeFile: nil), .stream(song.assetURL))
    }

    @MainActor
    func testTheHostBuildsALoaderAssetForAnUncachedRemoteTrackAndAFileAssetOtherwise() throws {
        let song = RemoteTrackPath(serverID: "no-such-server", songID: "no-such-song")
        let remote = Track(
            fileURL: song.assetURL, title: "T", artist: "A", albumTitle: "B", albumArtist: nil,
            trackNumber: 1, duration: 10, artwork: nil, dbID: nil
        )
        let local = Track(
            fileURL: URL(fileURLWithPath: "/tmp/local.flac"), title: "T", artist: "A", albumTitle: "B", albumArtist: nil,
            trackNumber: 1, duration: 10, artwork: nil, dbID: nil
        )
        let host = try XCTUnwrap(AudioPlayer.shared as? AudioPlayer)

        XCTAssertEqual(host.remoteAsset(for: remote).url, song.assetURL)
        XCTAssertEqual(host.remoteAsset(for: local).url, local.fileURL)
    }

    private func makeCache() -> RemoteStreamCache {
        RemoteStreamCache(
            cachesRoot: RemoteCacheLayout.cachesRoot(base: directory.appendingPathComponent("caches", isDirectory: true)),
            pinnedRoot: RemoteCacheLayout.pinnedRoot(base: directory.appendingPathComponent("support", isDirectory: true))
        )
    }

    @discardableResult
    private func writeCached(
        _ song: RemoteTrackPath, bytes: Int, coveredUpTo: Int64, in cache: RemoteStreamCache,
        lastUsed: Date = Date(), pinned: Bool = false
    ) throws -> URL {
        let root = pinned ? cache.pinnedRoot : cache.cachesRoot
        let audio = RemoteCacheLayout.audioURL(in: root, song: song, suffix: "flac")
        try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: audio)
        var ranges = ByteRangeSet()
        ranges.insert(0..<coveredUpTo)
        let sidecar = RemoteCacheSidecar(file: audio.lastPathComponent, total: Int64(bytes), ranges: ranges, lastUsed: lastUsed)
        try sidecar.encoded().write(to: RemoteCacheLayout.sidecarURL(in: root, song: song))
        return audio
    }
}
