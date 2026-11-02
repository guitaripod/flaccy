import FlaccyCore
import FlaccyEngine
import Foundation
import MidgarCore
import Network

/// Fetches the lyrics of the whole library in the background, so they are
/// already stored when a song plays and a lrclib having a bad hour never
/// reaches the listener. It works down the planner's order (the queue, then
/// habit, then the rest) one song at a time behind the same gate as the lyrics
/// view, rests when lrclib or the network does, and asks again about a song
/// lrclib could not answer for after a pause that grows with each failure.
/// Mirrors the Linux lane in `linux/src/precache/lyrics_lane.rs`.
actor LyricsPrecache {

    static let shared = LyricsPrecache()

    /// How long changes are left to settle before the lane replans: skipping
    /// through a queue should cost one plan, not twenty.
    private static let settle: Duration = .milliseconds(1500)

    /// How long the plays that rank the library are kept before they are read
    /// again.
    private static let tallyLifetime: TimeInterval = 10 * 60

    /// How long the lane sleeps when the network is unusable; a change of path
    /// wakes it sooner.
    private static let heldBackNap: TimeInterval = 30 * 60

    private static let day: TimeInterval = 24 * 60 * 60

    private struct Tally {
        var recent = 0
        var total = 0
    }

    private struct QueueEntry: Sendable {
        let key: String
        let albumTitle: String
        let credit: String
    }

    private var generation = 0
    private var run: Task<Void, Never>?
    private var settling: Task<Void, Never>?
    private var nap: Task<Void, Never>?
    private var ledger = PrecacheRetryLedger()
    private var breaker = LaneBreaker()
    private var tallies: (taken: Date, plays: [String: Tally])?
    private var isHeldBack = false
    private var isWatching = false
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.midgarcorp.flaccy.lyrics.network")

    private init() {}

    /// Asks the lane to look at the library again: it has changed, a song
    /// started, or the app came back. The first call starts the lane.
    nonisolated func refresh() {
        Task(priority: .utility) { await self.requestPass() }
    }

    /// A DEBUG screenshot launch or a test host has a fictional catalog that
    /// lrclib should never hear about.
    private static var isSuppressed: Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return true }
        #if DEBUG && (targetEnvironment(simulator) || os(macOS))
        return ScreenshotSeeder.isActive
        #elseif DEBUG
        return ScanBench.isRunning
        #else
        return false
        #endif
    }

    private func requestPass() async {
        guard !Self.isSuppressed else { return }
        await watchNetworkAndPlayer()
        settling?.cancel()
        settling = Task {
            try? await Task.sleep(for: Self.settle)
            guard !Task.isCancelled else { return }
            beginPass()
        }
    }

    private func beginPass() {
        generation += 1
        nap?.cancel()
        guard run == nil else { return }
        run = Task(priority: .utility) {
            await drain()
        }
    }

    private func watchNetworkAndPlayer() async {
        guard !isWatching else { return }
        isWatching = true
        monitor.pathUpdateHandler = { path in
            Task { await LyricsPrecache.shared.pathChanged(path) }
        }
        monitor.start(queue: monitorQueue)
        await Self.observePlayer()
    }

    /// A song starting or the queue changing is a reason to replan, since the
    /// queue is what the lane fetches first.
    @MainActor
    private static func observePlayer() {
        for name in [AudioPlayer.trackDidChange, AudioPlayer.queueDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                LyricsPrecache.shared.refresh()
            }
        }
    }

    /// Preparing ahead is never worth a connection that is missing or that the
    /// listener pays for by the byte or has asked to keep light.
    private func pathChanged(_ path: NWPath) {
        let wasHeldBack = isHeldBack
        isHeldBack = path.status != .satisfied || path.isExpensive || path.isConstrained
        if wasHeldBack && !isHeldBack { nap?.cancel() }
    }

    private func drain() async {
        defer { run = nil }
        while !Task.isCancelled {
            let seen = generation
            let songs = await plan()
            guard generation == seen else { continue }
            let now = Date()
            let due = songs.filter { !ledger.isWaiting(Self.key(of: $0), now: now) }
            if due.isEmpty {
                guard let next = ledger.nextDue(now: now) else { return }
                await rest(for: next.timeIntervalSince(now))
                continue
            }
            for song in due {
                guard generation == seen, !Task.isCancelled else { break }
                guard await waitUntilClear(seen: seen) else { break }
                await fetch(song)
            }
        }
    }

    /// Sleeps until the breaker, a cooldown lrclib asked for and an unusable
    /// network all allow a request. False means the plan changed meanwhile.
    private func waitUntilClear(seen: Int) async -> Bool {
        while !Task.isCancelled {
            guard generation == seen else { return false }
            let cooldown = await LyricsRequestGate.shared.cooldownLeft()
            let pause = max(breaker.restLeft(now: Date()), cooldown)
            if pause > 0 {
                await rest(for: pause)
            } else if isHeldBack {
                await rest(for: Self.heldBackNap)
            } else {
                return true
            }
        }
        return false
    }

    /// Sleeps, unless a newer plan or a change of network path wakes the lane.
    private func rest(for seconds: TimeInterval) async {
        let nap = Task { _ = try? await Task.sleep(for: .seconds(max(seconds, 0.5))) }
        self.nap = nap
        await nap.value
    }

    private func fetch(_ song: LyricsWant) async {
        let key = Self.key(of: song)
        let outcome = await LyricsService.shared.fetchLyrics(
            track: song.title, artist: song.artist, album: song.albumTitle,
            fileURL: Track.fileURL(forStoredPath: song.storedPath), duration: song.duration
        )
        switch outcome {
        case .failed(let failure):
            let kind = Self.kind(of: failure)
            let now = Date()
            breaker.failed(kind, now: now, jitter: .random(in: 0..<1))
            ledger.failed(key, kind, now: now, jitter: .random(in: 0..<1))
            MidgarLog.info("Lyrics for \(song.title) could not be fetched ahead of time (\(failure))", category: .content)
        case .found, .missing:
            guard Self.isStored(song) else {
                MidgarLog.info("Lyrics for \(song.title) are still not stored after the lookup, asking again later", category: .content)
                breaker.failed(.transient, now: Date(), jitter: .random(in: 0..<1))
                ledger.failed(key, .transient, now: Date(), jitter: .random(in: 0..<1))
                return
            }
            breaker.succeeded()
            ledger.succeeded(key)
        }
    }

    /// Whether the lookup left a current answer behind. A lookup lrclib could
    /// not answer for is served from an older stored row, or from nothing, and
    /// that is not a song done.
    private static func isStored(_ song: LyricsWant) -> Bool {
        guard let record = try? DatabaseManager.shared.fetchLyrics(trackTitle: song.title, artist: song.artist) else {
            return false
        }
        return LyricsResolution.isCurrent(record)
    }

    private static func key(of song: LyricsWant) -> String {
        song.title + "\u{0}" + song.artist
    }

    private static func kind(of failure: LyricsFailure) -> PrecacheFailure {
        switch failure {
        case .busy: return .throttled
        case .rejected: return .blocked
        case .server where LyricsPatience.triesNextQuestion(after: failure): return .busy
        case .unreachable, .timedOut, .server: return .transient
        }
    }

    /// The songs that still need a lookup, most wanted first.
    private func plan() async -> [LyricsWant] {
        let queue = await Self.queueAhead()
        let wants: [LyricsWant]
        do {
            wants = try DatabaseManager.shared.songsWantingLyrics(
                revision: LyricsResolution.revision,
                missesFetchedBefore: Date().addingTimeInterval(-LyricsResolution.missTTL)
            )
        } catch {
            MidgarLog.error("Listing the songs that need lyrics failed: \(error.localizedDescription)", category: .content)
            return []
        }
        let plays = playTallies()
        var distance: [String: Int] = [:]
        for (index, entry) in queue.enumerated() where distance[entry.key] == nil {
            distance[entry.key] = index
        }
        let playing = queue.first
        let now = Date()
        let candidates = wants.map { want in
            let key = Self.key(of: want)
            let tally = plays[ListenHistory.trackKey(title: want.title, artist: want.artist)]
            let sibling = playing.map {
                $0.key != key && $0.albumTitle == want.albumTitle && $0.credit == (want.albumArtist ?? want.artist)
            } ?? false
            return PrecacheCandidate(
                key: key, queueDistance: distance[key], albumSibling: sibling,
                plays30Days: tally?.recent ?? 0, playsTotal: tally?.total ?? 0,
                daysSincePlayed: want.lastPlayed.map { max(now.timeIntervalSince($0), 0) / Self.day },
                daysSinceAdded: max(now.timeIntervalSince(want.dateAdded), 0) / Self.day
            )
        }
        let byKey = Dictionary(wants.map { (Self.key(of: $0), $0) }, uniquingKeysWith: { first, _ in first })
        return PrecachePlan.lyricsOrder(candidates, wholeLibrary: true).compactMap { byKey[$0] }
    }

    /// The playing song and the ones queued behind it.
    @MainActor
    private static func queueAhead() -> [QueueEntry] {
        let player = AudioPlayer.shared
        return player.queue
            .dropFirst(max(player.currentIndex, 0))
            .prefix(PrecachePlan.lyricsQueueDepth + 1)
            .map { QueueEntry(key: $0.title + "\u{0}" + $0.artist, albumTitle: $0.albumTitle, credit: $0.albumArtist ?? $0.artist) }
    }

    private func playTallies() -> [String: Tally] {
        if let tallies, Date().timeIntervalSince(tallies.taken) < Self.tallyLifetime { return tallies.plays }
        let recentSince = Date().addingTimeInterval(-30 * Self.day)
        var plays: [String: Tally] = [:]
        for listen in (try? DatabaseManager.shared.fetchListens()) ?? [] {
            plays[listen.key, default: Tally()].total += 1
            if listen.timestamp >= recentSince { plays[listen.key, default: Tally()].recent += 1 }
        }
        tallies = (Date(), plays)
        return plays
    }
}
