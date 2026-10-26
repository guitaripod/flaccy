import FlaccyCore
import FlaccyServerCore
import Foundation
import GRDB
import XCTest

@testable import FlaccyEngine

extension FakeFlaccyServer {
    func titles(in name: String) -> [String] {
        guard let doc = playlist(named: name) else { return [] }
        return doc.entries.filter(\.alive).sorted { ($0.pos, $0.id) < ($1.pos, $1.id) }.map(\.song.title)
    }
}

final class ServerSyncEngineTests: XCTestCase {

    private func makePlaylist(_ device: SyncDevice, _ name: String, _ titles: [String]) throws -> Int64 {
        let songs = try titles.map { try device.addTrack($0, path: "Artist/Album/\($0).flac") }
        let playlist = try XCTUnwrap(device.database.createPlaylist(name: name).id)
        try device.database.addTracksToPlaylist(playlistId: playlist, trackFileURLs: songs.map(\.fileURL))
        return playlist
    }

    func testConnectingEnrollsStoresTheTokenAndTurnsTheRecorderOn() async throws {
        let server = FakeFlaccyServer()
        let device = try makeDevice(server)
        let connection = try await device.connect()
        XCTAssertEqual(connection.serverName, "Fake")
        XCTAssertTrue(device.database.serverSyncGate.isConfigured)
        XCTAssertFalse(device.tokens.isEmpty)
        let isConnected = await device.engine.isConnected
        XCTAssertTrue(isConnected)
        XCTAssertEqual(server.callCount("hello"), 1)
        XCTAssertEqual(server.callCount("enroll"), 1)
    }

    func testConnectingRefusesAServerThisBuildCannotSpeakToAndAttachesNothing() async throws {
        let server = FakeFlaccyServer()
        let device = try makeDevice(server)
        server.protocols = [2]
        await assertFails(.appTooOld) { _ = try await device.connect() }
        server.protocols = [0]
        await assertFails(.serverTooOld) { _ = try await device.connect() }
        server.protocols = [1]
        server.features = ["live"]
        await assertFails(.serverTooOld) { _ = try await device.connect() }
        server.features = ["sync"]
        await assertFails(.enrollInvalid) { _ = try await device.connect(code: "WRONG") }
        XCTAssertFalse(device.database.serverSyncGate.isConfigured)
        XCTAssertTrue(device.tokens.isEmpty)
    }

    private func assertFails(_ expected: ServerSyncError, _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ServerSyncError, expected, file: file, line: line)
        }
    }

    func testPlaylistEditsReachTheServerInOrderAndAPullRetiresThem() async throws {
        let server = FakeFlaccyServer()
        let device = try makeDevice(server)
        _ = try await device.connect()
        let playlist = try makePlaylist(device, "Mix", ["One", "Two", "Three"])
        try device.database.renamePlaylist(id: playlist, name: "Mix 2")
        assertUpToDate(await device.settle())
        XCTAssertEqual(server.titles(in: "Mix 2"), ["One", "Two", "Three"])
        let pending = await device.engine.pendingChangeCount()
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(try device.playlistTitles("Mix 2"), ["One", "Two", "Three"])
    }

    func testAPushAnswerAloneNeverRetiresAMutationOnlyACompletePullDoes() async throws {
        let server = FakeFlaccyServer()
        let device = try makeDevice(server)
        _ = try await device.connect()
        _ = try makePlaylist(device, "Mix", ["One", "Two"])
        let store = ServerSyncStore(database: device.database)
        let transport = server.transport(token: device.tokens.token(serverID: "fake:4545"))
        let request = try XCTUnwrap(store.nextPush())
        let response = try await transport.push(request, incarnation: server.incarnation)
        _ = try store.onPushResponse(instance: request.instance, response: response, localNowMs: 0)
        let rows = try device.pendingRows()
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy(\.acked))
        let pullRequest = try store.pullRequest()

        server.pageCap = 1
        let first = try await transport.pull(since: 0, limit: 5_000, instance: pullRequest.instance, incarnation: nil)
        XCTAssertTrue(first.more)
        XCTAssertEqual(first.lastMutationId, 2)
        _ = try store.onPullPage(request: pullRequest, response: first, localNowMs: 0)
        XCTAssertEqual(try device.pendingRows().count, 2, "a page with more to come retires nothing")

        var next = try store.pullRequest()
        XCTAssertEqual(next.since, first.changes.last?.seq)
        while true {
            let page = try await transport.pull(since: next.since, limit: 5_000, instance: next.instance, incarnation: nil)
            _ = try store.onPullPage(request: next, response: page, localNowMs: 0)
            if !page.more { break }
            next = try store.pullRequest()
        }
        XCTAssertEqual(try device.pendingRows().count, 0)
        XCTAssertEqual(try store.pullRequest().since, server.seq)
    }

    func testAMutationTheServerAnsweredIsKeptWhileATooEarlyPullCannotConfirmIt() async throws {
        let server = FakeFlaccyServer()
        let device = try makeDevice(server)
        _ = try await device.connect()
        _ = try device.database.createPlaylist(name: "Mix")
        server.dropNextPushResponse = true
        let first = await device.settle()
        XCTAssertEqual(first, .unreachable(server: "Fake"))
        XCTAssertEqual(try device.pendingRows().map(\.acked), [false])
        assertUpToDate(await device.settle())
        XCTAssertEqual(server.snapshot().playlists.count, 1)
        XCTAssertEqual(server.allPushes().count, 2)
        XCTAssertEqual(server.allPushes()[0].mutations, server.allPushes()[1].mutations)
        let pending = await device.engine.pendingChangeCount()
        XCTAssertEqual(pending, 0)
    }

    func testEditsMadeOfflineWaitInOrderAndGoOutWhenTheServerIsBack() async throws {
        let server = FakeFlaccyServer()
        let device = try makeDevice(server)
        _ = try await device.connect()
        server.online = false
        server.noNetwork = true
        let playlist = try makePlaylist(device, "Mix", ["One", "Two"])
        try device.database.renamePlaylist(id: playlist, name: "Offline Mix")
        let status = await device.settle()
        XCTAssertEqual(status, .offline(server: "Fake", pending: 3))
        XCTAssertEqual(try device.pendingNames(), ["playlist.create", "entry.insertMany", "playlist.rename"])
        XCTAssertEqual(try device.playlistTitles("Offline Mix"), ["One", "Two"])
        server.online = true
        assertUpToDate(await device.settle())
        XCTAssertEqual(server.titles(in: "Offline Mix"), ["One", "Two"])
    }

    func testATransientFailureIsRetriedWithJitteredBackoffAndARefusalIsNot() async throws {
        let server = FakeFlaccyServer()
        let schedule = ServerSyncBackoff(baseSeconds: 1, maxSeconds: 8, attempts: 4)
        let device = try makeDevice(server, backoff: schedule)
        _ = try await device.connect()
        _ = try device.database.createPlaylist(name: "Mix")
        server.queuedFailures = [.offline("x"), .timedOut]
        assertUpToDate(await device.settle())
        XCTAssertEqual(device.recordedPauses, [schedule.pause(attempt: 0, jitter: 0.5), schedule.pause(attempt: 1, jitter: 0.5)])
        XCTAssertEqual(device.recordedPauses, [0.75, 1.5])

        server.revokeAll()
        _ = try device.database.createPlaylist(name: "Second")
        let status = await device.settle()
        XCTAssertEqual(status, .deviceRemoved(server: "Fake"))
        XCTAssertEqual(device.recordedPauses.count, 2)
    }

    func testClockBehindOnPushShowsTheClockLineAndKeepsTheWriteQueued() async throws {
        let server = FakeFlaccyServer()
        let device = try makeDevice(server)
        _ = try await device.connect()
        _ = try device.database.createPlaylist(name: "Mix")
        server.queuedPushFailures = [.clockBehind]
        let status = await device.settle()
        XCTAssertEqual(status, .serverClockWrong(server: "Fake"))
        let pending = await device.engine.pendingChangeCount()
        XCTAssertEqual(pending, 1)
        assertUpToDate(await device.settle())
    }

    func testWithoutProNothingGoesOutButWritesKeepQueueing() async throws {
        let server = FakeFlaccyServer()
        let device = try makeDevice(server)
        _ = try await device.connect()
        device.entitled = false
        _ = try device.database.createPlaylist(name: "Mix")
        let status = await device.settle()
        XCTAssertEqual(status, .notPro)
        XCTAssertEqual(server.callCount("pull"), 0)
        let queued = await device.engine.pendingChangeCount()
        XCTAssertEqual(queued, 1)
        device.entitled = true
        assertUpToDate(await device.settle())
        XCTAssertEqual(server.snapshot().playlists.count, 1)
    }

    func testPausingStopsRoundsAndResumingSendsWhatQueued() async throws {
        let server = FakeFlaccyServer()
        let device = try makeDevice(server)
        _ = try await device.connect()
        await device.engine.setPaused(true)
        _ = try device.database.createPlaylist(name: "Mix")
        let paused = await device.settle()
        XCTAssertEqual(paused, .paused)
        XCTAssertEqual(server.callCount("push"), 0)
        await device.engine.setPaused(false)
        assertUpToDate(await device.settle())
        XCTAssertEqual(server.snapshot().playlists.count, 1)
    }

    func testBackgroundRefreshAnswersWhetherEverythingIsSent() async throws {
        let server = FakeFlaccyServer()
        let device = try makeDevice(server)
        let notConnected = await device.engine.performBackgroundRefresh()
        XCTAssertFalse(notConnected)
        _ = try await device.connect()
        _ = try device.database.createPlaylist(name: "Mix")
        let sent = await device.engine.performBackgroundRefresh()
        XCTAssertTrue(sent)
        server.online = false
        _ = try device.database.createPlaylist(name: "Second")
        let offline = await device.engine.performBackgroundRefresh()
        XCTAssertFalse(offline)
    }

    func testTheStatusStreamStartsWithTheCurrentStateAndEndsUpToDate() async throws {
        let server = FakeFlaccyServer()
        let device = try makeDevice(server)
        let before = await device.engine.status
        XCTAssertEqual(before, .notConnected)
        _ = try await device.connect()
        _ = try device.database.createPlaylist(name: "Mix")
        let stream = await device.engine.statusUpdates()
        let reader = Task { () -> [SyncStatus] in
            var seen: [SyncStatus] = []
            for await status in stream {
                seen.append(status)
                if case .upToDate = status { break }
            }
            return seen
        }
        _ = await device.settle()
        let statuses = await reader.value
        guard case .syncing? = statuses.first else { return XCTFail("\(statuses)") }
        guard case .upToDate? = statuses.last else { return XCTFail("\(statuses)") }
    }

    func testDevicesCanBeListedRenamedAndRemoved() async throws {
        let server = FakeFlaccyServer()
        let first = try makeDevice(server)
        let second = try makeDevice(server)
        server.newCode("SECOND")
        _ = try await first.connect()
        _ = try await second.connect(code: "SECOND")
        let devices = try await first.engine.devices()
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices.filter(\.current).count, 1)
        let other = try XCTUnwrap(devices.first { !$0.current })
        try await first.engine.renameDevice(id: other.id, name: "Kitchen iPad")
        let renamed = try await first.engine.devices()
        XCTAssertTrue(renamed.contains { $0.name == "Kitchen iPad" })
        try await first.engine.removeDevice(id: other.id)
        let remaining = try await first.engine.devices()
        XCTAssertEqual(remaining.count, 1)
        _ = try second.database.createPlaylist(name: "Mix")
        let status = await second.settle()
        XCTAssertEqual(status, .deviceRemoved(server: "Fake"))
    }

    func testRecordedWritesAnnounceOncePerTransactionAfterItCommits() async throws {
        let server = FakeFlaccyServer()
        let device = try makeDevice(server)
        _ = try await device.connect()
        let counter = Counter()
        device.database.serverSyncGate.onRecorded { counter.bump() }
        let song = try device.addTrack("One")
        XCTAssertEqual(counter.value, 0)
        let playlist = try XCTUnwrap(device.database.createPlaylist(name: "Mix").id)
        XCTAssertEqual(counter.value, 1)
        try device.database.addTracksToPlaylist(playlistId: playlist, trackFileURLs: [song.fileURL, song.fileURL])
        XCTAssertEqual(counter.value, 2)
    }

    func testDisconnectingKeepsEverythingLocalAndStopsRecording() async throws {
        let server = FakeFlaccyServer()
        let device = try makeDevice(server)
        _ = try makePlaylist(device, "Mix", ["One"])
        _ = try await device.connect()
        assertUpToDate(await device.settle())
        try await device.engine.disconnect()
        XCTAssertFalse(device.database.serverSyncGate.isConfigured)
        XCTAssertTrue(device.tokens.isEmpty)
        let status = await device.engine.status
        XCTAssertEqual(status, .notConnected)
        XCTAssertEqual(try device.playlistTitles("Mix"), ["One"])
        _ = try device.database.createPlaylist(name: "After")
        XCTAssertEqual(try device.pendingNames(), [])
        XCTAssertEqual(try device.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_base") }, 0)
        XCTAssertEqual(server.snapshot().playlists.count, 1)
    }

    func testAPullPageForARequestTheEngineMovedPastIsIgnored() async throws {
        let server = FakeFlaccyServer()
        let device = try makeDevice(server)
        _ = try await device.connect()
        let store = ServerSyncStore(database: device.database)
        let stale = try store.pullRequest()
        _ = try device.database.createPlaylist(name: "Mix")
        _ = await device.settle()
        let cursor = try store.pullRequest().since
        XCTAssertGreaterThan(cursor, 0)
        let transport = server.transport(token: device.tokens.token(serverID: "fake:4545"))
        let page = try await transport.pull(since: 0, limit: 5_000, instance: stale.instance, incarnation: nil)
        guard case .stale = try store.onPullPage(request: stale, response: page, localNowMs: 0) else { return XCTFail("not stale") }
        XCTAssertEqual(try store.pullRequest().since, cursor)
    }

    func testThePullCursorIsCommittedWithItsPageSoAnInterruptedSyncResumesThere() async throws {
        let server = FakeFlaccyServer()
        let device = try makeDevice(server)
        try server.plantSessions(5)
        server.pageCap = 2
        _ = try await device.connect()
        let store = ServerSyncStore(database: device.database)
        let transport = server.transport(token: device.tokens.token(serverID: "fake:4545"))
        let request = try store.pullRequest()
        let page = try await transport.pull(since: request.since, limit: request.limit, instance: request.instance, incarnation: nil)
        guard case .applied(let more, _) = try store.onPullPage(request: request, response: page, localNowMs: 0) else { return XCTFail() }
        XCTAssertTrue(more)
        XCTAssertEqual(try store.pullRequest().since, page.changes.last?.seq)
        XCTAssertEqual(try device.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_base") }, 2)

        let resumed = ServerSyncEngine(
            database: device.database,
            configuration: ServerSyncConfiguration(transports: FakeTransports(server: server), tokens: device.tokens, backoff: .none, platform: "ios")
        )
        assertUpToDate(await resumed.syncNow())
        XCTAssertEqual(server.pullSinces.first, 0)
        XCTAssertEqual(server.pullSinces[1], page.changes.last?.seq)
        XCTAssertEqual(try device.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_base") }, 5)
    }

    func testAPageLargerThanTheChunkSizeIsStoredWholeAcrossSeveralTransactions() async throws {
        let server = FakeFlaccyServer()
        let device = try makeDevice(server)
        try server.plantSessions(12_000)
        server.oversizedPageOnce = true
        _ = try await device.connect()
        assertUpToDate(await device.settle())
        XCTAssertEqual(try device.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_base WHERE kind = 'session'") }, 12_000)
        XCTAssertEqual(ServerSyncStore.applyChunkRows, 5_000)
        XCTAssertEqual(ServerSyncStore.pullLimit, 5_000)
        XCTAssertEqual(server.pullSinces.count, 1)
        XCTAssertEqual(try ServerSyncStore(database: device.database).pullRequest().since, server.seq)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
