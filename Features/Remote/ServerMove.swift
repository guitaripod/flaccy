import FlaccyCore
import FlaccyEngine
import Foundation
import MidgarCore
#if canImport(UIKit)
import UIKit
#endif
#if os(macOS)
import FlaccyServerEmbed
#endif

/// What the person wants for the songs on this device that a server also holds.
nonisolated enum ServerMoveChoice: Equatable, Sendable {
    /// Play them from the server and let their files go, keeping the loved ones downloaded when `keepLoved` is on.
    case stream(keepLoved: Bool)
    /// Play them from the server and keep their files here as downloads, so they still play offline.
    case keepDownloaded
}

/// What moving to a server would do: which songs on this device it holds, how much room their files take, and how many
/// songs stay because the server does not have them.
nonisolated struct ServerMoveOffer: Equatable, Sendable {
    let serverID: String
    let serverName: String
    let pairs: [ServerMovePlan.Pair]
    let duplicates: [ServerMovePlan.Pair]
    /// The size of each pair's file on this device, by the server song.
    let pairBytes: [String: Int64]
    /// The size of every further copy, which always goes.
    let duplicateBytes: Int64
    /// The server songs the person loves on this device.
    let lovedServerPaths: Set<String>
    /// Songs on this device that stay: the server does not have them, or an earlier mix is kept beside them.
    let staying: Int

    /// The songs that would play from the server; further copies of them only add to the room freed.
    var songs: Int { pairs.count }
    var lovedSongs: Int { lovedServerPaths.count }
    var bytes: Int64 { pairBytes.values.reduce(0, +) + duplicateBytes }
    var lovedBytes: Int64 { lovedServerPaths.reduce(0) { $0 + (pairBytes[$1] ?? 0) } }

    func keepsOnDevice(_ serverPath: String, choice: ServerMoveChoice) -> Bool {
        switch choice {
        case .keepDownloaded: true
        case .stream(let keepLoved): keepLoved && lovedServerPaths.contains(serverPath)
        }
    }

    func bytesFreed(by choice: ServerMoveChoice) -> Int64 {
        let kept = pairs.reduce(Int64(0)) { total, pair in
            keepsOnDevice(pair.server, choice: choice) ? total + (pairBytes[pair.server] ?? 0) : total
        }
        return bytes - kept
    }

    /// The pairs first, so every further copy folds into a song that already plays from the server.
    func steps(for choice: ServerMoveChoice) -> [ServerMoveStep] {
        pairs.map { .pair(local: $0.local, server: $0.server, keepOnDevice: keepsOnDevice($0.server, choice: choice)) }
            + duplicates.map { .duplicate(local: $0.local, server: $0.server) }
    }

    /// Whether every song stays on this device, so the move needs nothing from the server right now.
    func keepsEverything(_ choice: ServerMoveChoice) -> Bool {
        pairs.allSatisfy { keepsOnDevice($0.server, choice: choice) }
    }
}

/// What a move did, for the closing words.
nonisolated struct ServerMoveSummary: Equatable, Sendable {
    let serverName: String
    let moved: Int
    let kept: Int
    let freedBytes: Int64
    let notKept: Int
    let staying: Int
}

/// Moves the songs on this device that a server also holds to that server's copies, on iPhone, iPad and the Mac.
///
/// The person sees one offer per server: how many songs the server has, the room their files take and how many stay.
/// Moving makes each song's row the server's song in the database, so it keeps its id, plays, love, playlist places,
/// song volume and lyrics; further copies of a song fold into it. Then the library, the queue and the watch learn the
/// new addresses, and the files leave the library folder: kept as downloads, or deleted (to the Trash on the Mac).
/// The database holds a journal of the files, so a move cut short finishes before the next library scan.
@MainActor
final class ServerMoveService {

    static let shared = ServerMoveService()
    static let didChange = Notification.Name("ServerMoveServiceDidChange")
    /// Posted after songs started playing from a server, so what keys songs by their path (the watch) can follow them.
    static let didMove = Notification.Name("ServerMoveServiceDidMove")
    nonisolated static let chunkSize = 250
    nonisolated static let freshness: TimeInterval = 600

    enum Phase: Equatable {
        case idle
        case checking
        case offer(ServerMoveOffer)
        case unavailable(String)
        case moving(done: Int, total: Int)
        case finished(ServerMoveSummary)
        case failed(String)
    }

    private(set) var phases: [String: Phase] = [:]
    /// The latest check per server; a check that a reset or a newer check overtook writes nothing.
    private var checks: [String: UUID] = [:]
    private var hasDeferredFiles = false
    private var filesTask: Task<ServerMoveFileOutcome, Never>?
    private var observers: [NSObjectProtocol] = []

    private init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: PlaybackEngine.trackDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishDeferredFiles() }
        })
    }

    func phase(for serverID: String) -> Phase {
        phases[serverID] ?? .idle
    }

    var isMoving: Bool {
        phases.values.contains { if case .moving = $0 { true } else { false } }
    }

    /// Works out what a move to the server would do, syncing its songs first when they may be out of date. An offer already on
    /// screen stays while it is checked again, then gives way to the fresh one.
    func prepare(serverID: String) async {
        if case .moving = phase(for: serverID) { return }
        if let reason = Self.unavailableReason() {
            set(.unavailable(reason), for: serverID)
            return
        }
        let check = UUID()
        checks[serverID] = check
        if case .offer = phase(for: serverID) {} else { set(.checking, for: serverID) }
        let result: Phase
        do {
            let record = try DatabaseManager.shared.fetchRemoteServer(id: serverID)
            if record?.lastSyncedAt.map({ Date().timeIntervalSince($0) > Self.freshness }) ?? true {
                try await RemoteCatalogSync.shared.sync(serverID: serverID)
            }
            result = .offer(try await Self.offer(serverID: serverID, name: record?.name ?? serverID))
        } catch {
            result = .failed(await Self.failureText(error, serverID: serverID))
        }
        guard checks[serverID] == check else { return }
        checks[serverID] = nil
        if case .moving = phase(for: serverID) { return }
        set(result, for: serverID)
    }

    /// The offer for a server without syncing it or changing any screen; nil when the server holds none of the songs here.
    func quietOffer(serverID: String) async -> ServerMoveOffer? {
        guard Self.unavailableReason() == nil,
              let record = try? DatabaseManager.shared.fetchRemoteServer(id: serverID),
              let offer = try? await Self.offer(serverID: serverID, name: record.name),
              offer.songs > 0
        else { return nil }
        return offer
    }

    /// Shows an offer worked out without changing any screen, for the one made right after a server is added.
    func show(_ offer: ServerMoveOffer) {
        guard !isMoving else { return }
        set(.offer(offer), for: offer.serverID)
    }

    /// Moves the songs of the offer the person accepted, and returns what it did, nil when it failed or another move runs.
    @discardableResult
    func start(_ offer: ServerMoveOffer, choice: ServerMoveChoice) async -> ServerMoveSummary? {
        let serverID = offer.serverID
        guard !isMoving else { return nil }
        let steps = offer.steps(for: choice)
        set(.moving(done: 0, total: steps.count), for: serverID)
        let finishBackgroundTask = Self.beginBackgroundTask()
        defer { finishBackgroundTask() }
        MidgarLog.info("Moving \(offer.pairs.count) songs and \(offer.duplicates.count) further copies to \(offer.serverName) (\(choice))", category: .content)
        if !offer.keepsEverything(choice) {
            do {
                _ = try await RemoteServers.shared.client(for: serverID).ping()
            } catch {
                MidgarLog.error("Moving to \(offer.serverName) stopped before it began: \(error.localizedDescription)", category: .content)
                set(.failed(await Self.failureText(error, serverID: serverID)), for: serverID)
                return nil
            }
        }
        let applied = await Self.apply(steps)
        let records = applied.records
        if !records.isEmpty {
            await adopt(records)
            set(.moving(done: 0, total: records.count), for: serverID)
        }
        let outcome = await handleFiles { [weak self] done in
            await self?.set(.moving(done: done, total: records.count), for: serverID)
        }
        if let error = applied.failure {
            MidgarLog.error("Moving to \(offer.serverName) stopped after \(records.count) of \(steps.count) songs: \(error.localizedDescription)", category: .content)
            set(.failed(await Self.failureText(error, serverID: serverID)), for: serverID)
            return nil
        }
        guard !records.isEmpty else {
            set(.failed(ServerMoveCopy.nothing(server: offer.serverName)), for: serverID)
            return nil
        }
        let summary = ServerMoveSummary(
            serverName: offer.serverName,
            moved: Set(records.map(\.remotePath)).count,
            kept: outcome.kept,
            freedBytes: outcome.freedBytes,
            notKept: outcome.notKept,
            staying: offer.staying
        )
        MidgarLog.info("Moved to \(offer.serverName): \(summary.moved) songs, \(summary.kept) kept, \(summary.freedBytes) bytes freed, \(summary.notKept) not kept, \(outcome.deferred) files waiting for the player", category: .content)
        set(.finished(summary), for: serverID)
        return summary
    }

    /// Forgets a finished, failed or declined move, so the server's screens show the plain state again.
    func reset(serverID: String) {
        if case .moving = phase(for: serverID) { return }
        checks[serverID] = nil
        phases[serverID] = nil
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Finishes the files a move left behind, before a library scan reads the folder.
    func finishMovedFiles() async {
        _ = await handleFiles()
    }

    /// Runs the file step one pass at a time, since a scan and a move can both ask for it and must not handle one file twice.
    private func handleFiles(progress: (@Sendable (Int) async -> Void)? = nil) async -> ServerMoveFileOutcome {
        let previous = filesTask
        let task = Task { [weak self] () -> ServerMoveFileOutcome in
            _ = await previous?.value
            let inUse = await self?.inUseLocalPaths() ?? []
            return await ServerMoveFiles.finishPending(sparing: inUse, progress: progress)
        }
        filesTask = task
        let outcome = await task.value
        hasDeferredFiles = outcome.deferred > 0
        return outcome
    }

    private func finishDeferredFiles() {
        guard hasDeferredFiles, !isMoving else { return }
        hasDeferredFiles = false
        Task { await finishMovedFiles() }
    }

    private func set(_ phase: Phase, for serverID: String) {
        phases[serverID] = phase
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Brings every part of the app that holds songs level with their new addresses.
    private func adopt(_ records: [ServerMoveRecord]) async {
        let remotePaths = Array(Set(records.map(\.remotePath)))
        RemoteSongDirectory.shared.invalidate(paths: remotePaths)
        NotificationCenter.default.post(name: Self.didMove, object: nil)
        await Library.shared.reloadFromDatabase()
        LovedTracksService.shared.reloadFromDatabase()
        let byPath = Dictionary(
            Library.shared.allTracks.compactMap { track in track.remoteSong.map { ($0.path, track) } },
            uniquingKeysWith: { first, _ in first }
        )
        var replacements: [URL: Track] = [:]
        for record in records {
            guard let track = byPath[record.remotePath] else { continue }
            replacements[LibraryPaths.root.appendingPathComponent(record.localPath, isDirectory: false)] = track
        }
        AudioPlayer.shared.replaceMovedTracks(replacements)
        for record in records where record.starOnServer {
            if let song = RemoteTrackPath(path: record.remotePath) { RemoteServerReports.setStarred(song, starred: true) }
        }
    }

    private func inUseLocalPaths() -> Set<String> {
        Set(AudioPlayer.shared.trackURLsInUse.filter(\.isFileURL).map(LibraryPaths.relativePath(of:)))
    }

    /// Applies the steps a chunk per transaction. A chunk that fails stops the rest, and the chunks before it are returned,
    /// since they already play from the server and their files are journaled.
    nonisolated private static func apply(_ steps: [ServerMoveStep]) async -> (records: [ServerMoveRecord], failure: (any Error)?) {
        await Task.detached(priority: .userInitiated) {
            var records: [ServerMoveRecord] = []
            var start = 0
            while start < steps.count {
                let chunk = Array(steps[start..<min(start + chunkSize, steps.count)])
                do {
                    records += try DatabaseManager.shared.applyServerMove(chunk, now: Date())
                } catch {
                    return (records, error)
                }
                start += chunkSize
            }
            return (records, nil)
        }.value
    }

    static func offer(serverID: String, name: String) async throws -> ServerMoveOffer {
        let onWatch = watchLocalPaths()
        let sampleNames = SampleMusicService.sampleFileNames
        return try await Task.detached(priority: .userInitiated) {
            let root = LibraryPaths.root
            let inventory = try DatabaseManager.shared.serverMoveInventory(
                serverID: serverID,
                excluded: { !$0.contains("/") && sampleNames.contains($0) },
                rank: { song in (onWatch.contains(song.path) ? 4 : 0) + (song.loved ? 2 : 0) + (song.playCount > 0 ? 1 : 0) }
            )
            let plan = ServerMovePlan.plan(local: inventory.local, server: inventory.server)
            func bytes(_ path: String) -> Int64 {
                inventory.localSongs[path]?.bytes
                    ?? Int64((try? root.appendingPathComponent(path, isDirectory: false).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            var pairBytes: [String: Int64] = [:]
            var loved = Set<String>()
            for pair in plan.pairs {
                pairBytes[pair.server] = bytes(pair.local)
                if inventory.localSongs[pair.local]?.loved == true { loved.insert(pair.server) }
            }
            for duplicate in plan.duplicates where inventory.localSongs[duplicate.local]?.loved == true {
                loved.insert(duplicate.server)
            }
            return ServerMoveOffer(
                serverID: serverID,
                serverName: name,
                pairs: plan.pairs,
                duplicates: plan.duplicates,
                pairBytes: pairBytes,
                duplicateBytes: plan.duplicates.reduce(0) { $0 + bytes($1.local) },
                lovedServerPaths: loved,
                staying: plan.unmatched.count + inventory.heldBack
            )
        }.value
    }

    /// The songs on this device the person put on their Apple Watch, so the copy on the watch is the one that moves.
    private static func watchLocalPaths() -> Set<String> {
        #if os(iOS)
        WatchSyncService.shared.localPathsOnWatch()
        #else
        []
        #endif
    }

    /// Why this device cannot move its songs: a Mac that shares its library serves those files to the person's other devices.
    private static func unavailableReason() -> String? {
        #if os(macOS)
        MacLibrarySharing.shared.isEnabled ? ServerMoveCopy.sharingMac : nil
        #else
        nil
        #endif
    }

    private static func failureText(_ error: any Error, serverID: String) async -> String {
        let host = await RemoteServers.shared.displayHost(for: serverID)
        return RemoteFailure.from(error, host: host).errorDescription ?? error.localizedDescription
    }

    private static func beginBackgroundTask() -> @MainActor () -> Void {
        #if canImport(UIKit)
        var identifier = UIBackgroundTaskIdentifier.invalid
        identifier = UIApplication.shared.beginBackgroundTask(withName: "ServerMove") {
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
        return {
            guard identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
        #else
        return {}
        #endif
    }
}

/// The servers already offered the move right after they were added, so that offer shows once per server.
nonisolated enum ServerMoveOfferLedger {

    private static let key = "flaccy.serverMove.offered"

    static func wasOffered(_ serverID: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(serverID)
    }

    static func markOffered(_ serverID: String) {
        var offered = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !offered.contains(serverID) else { return }
        offered.append(serverID)
        UserDefaults.standard.set(offered, forKey: key)
    }
}
