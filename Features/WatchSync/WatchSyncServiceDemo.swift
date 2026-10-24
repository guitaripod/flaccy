import MidgarCore
#if DEBUG && os(iOS) && targetEnvironment(simulator)
import FlaccyCore
import Foundation
import WatchConnectivity

/// Fills the sync service for App Store screenshots without touching
/// WatchConnectivity: a paired watch with Flaccy installed, half the fictional
/// library delivered, two albums mid-send at different points, one being
/// prepared and one failed. Reachable only on the Simulator in DEBUG builds,
/// only with `--seed-screenshots` and `--demo-watch-sync`. `--demo-watch-state`
/// takes `notInstalled`, `notPaired`, `waiting` or `ready` (the default) to stage
/// the screen as it reads when the watch cannot take music.
extension WatchSyncService {

    static let demoLaunchArgument = "--demo-watch-sync"
    static let demoStateArgument = "--demo-watch-state"

    enum DemoWatchState: String {
        case notInstalled
        case notPaired
        case waiting
        case ready

        var link: WatchSyncLink {
            switch self {
            case .notInstalled: WatchSyncLink(isSupported: true, isPaired: true, isInstalled: false)
            case .notPaired: WatchSyncLink(isSupported: true, isPaired: false, isInstalled: false)
            case .waiting: WatchSyncLink(isSupported: true, isPaired: true, isInstalled: true, hasAnswered: false, isReachable: false)
            case .ready: WatchSyncLink(isSupported: true, isPaired: true, isInstalled: true)
            }
        }
    }

    static var demoWatchState: DemoWatchState {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: demoStateArgument), arguments.indices.contains(index + 1) else { return .ready }
        return DemoWatchState(rawValue: arguments[index + 1]) ?? .ready
    }

    private static var demoLedger: WatchSyncLedger?

    private static let demoWatchTotalBytes: Int64 = 31_600_000_000
    private static let demoWatchUsedBytes: Int64 = 11_200_000_000
    private static let demoWatchFreeBytes: Int64 = 14_100_000_000

    private enum DemoPlan {
        case synced
        case notSynced
        case sending(Double)
        case preparing
        case failed
        case partial(Int)
        case queued
    }

    func installDemoState() {
        let arguments = CommandLine.arguments
        guard arguments.contains(Self.demoLaunchArgument), arguments.contains(ScreenshotSeeder.launchArgument) else { return }
        guard Self.demoLedger == nil else { return }
        guard Library.shared.albums.count >= 10 else { return }

        wcSession?.delegate = nil
        WatchSyncLink.simulated = Self.demoWatchState.link
        WatchSyncSizing.sourceBytes = { track in Self.demoSourceBytes(of: track) }
        buildDemoState()
        MidgarLog.info("Watch sync demo state installed", category: .connectivity)
        notify()
    }

    /// A paired watch simulator answers the real session with its own heartbeat
    /// and would overwrite the staged state, so the screen puts the staged ledger
    /// back whenever the engine has disturbed it.
    func restoreDemoStateIfDisturbed() {
        guard let staged = Self.demoLedger, ledger.requested.count <= staged.requested.count else { return }
        guard ledger != staged || watchTotalBytes != Self.demoWatchTotalBytes else { return }
        buildDemoState()
    }

    private func buildDemoState() {
        let albums = Library.shared.albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let plans = albums.indices.map { Self.demoPlan(forIndex: $0, state: Self.demoWatchState) }
        hasHeartbeat = false
        fillLedger(albums: albums, plans: plans)
        applyHeartbeat(used: Self.demoWatchUsedBytes, total: Self.demoWatchTotalBytes)
        startDemoMetrics()
        Self.demoLedger = ledger
    }

    private static func demoPlan(forIndex index: Int, state: DemoWatchState) -> DemoPlan {
        switch state {
        case .notInstalled, .notPaired: return .notSynced
        case .waiting: return index == 1 || index == 4 ? .queued : .notSynced
        case .ready: break
        }
        return switch index {
        case 1: .sending(0.62)
        case 3: .preparing
        case 5: .sending(0.28)
        case 8: .partial(2)
        default: index % 2 == 0 ? .synced : .notSynced
        }
    }

    /// A believable size for the one-second-per-kilobyte fictional files: what a
    /// FLAC of this length, rate and depth would weigh.
    nonisolated private static func demoSourceBytes(of track: Track) -> Int64 {
        let rate = Double(track.sampleRate ?? 44_100)
        let depth = Double(track.bitDepth ?? 16)
        return Int64(track.duration * rate * 2 * depth / 8 * 0.58)
    }

    private func fillLedger(albums: [Album], plans: [DemoPlan]) {
        let policy = WatchSyncLedger.Policy(maxInFlightCount: 256, maxInFlightBytes: .max, ackGrace: 600)
        var ledger = WatchSyncLedger(policy: policy)
        let now = Date()
        var confirmed = Set<String>()
        var inProgress: [(album: Album, plan: DemoPlan)] = []

        for (album, plan) in zip(albums, plans) {
            let stems = album.tracks.map { stem(of: $0) }
            switch plan {
            case .notSynced:
                continue
            case .synced:
                ledger.request(requestItems(for: album), now: now)
                confirmed.formUnion(stems)
            case let .partial(count):
                let delivered = Array(album.tracks.prefix(count))
                ledger.request(requestItems(for: Album.demoSubset(album, tracks: delivered)), now: now)
                confirmed.formUnion(delivered.map { stem(of: $0) })
            case .queued:
                ledger.request(requestItems(for: album), now: now)
            case .sending, .preparing, .failed:
                ledger.request(requestItems(for: album), now: now)
                inProgress.append((album, plan))
            }
        }
        ledger.ingest(confirmed: confirmed, watchFreeBytes: Self.demoWatchFreeBytes, watchIsFull: false, now: now)
        if Self.demoWatchState != .waiting { _ = ledger.nextToStart(now: now) }

        for (album, plan) in inProgress {
            shape(album: album, plan: plan, in: &ledger, now: now)
        }
        self.ledger = ledger
        recordRun(albums: inProgress.map(\.album))
    }

    private func requestItems(for album: Album) -> [(stem: String, bytes: Int64)] {
        album.tracks.map { (stem: stem(of: $0), bytes: WatchSyncSizing.estimatedBytes(for: $0, profile: profile)) }
    }

    private func shape(album: Album, plan: DemoPlan, in ledger: inout WatchSyncLedger, now: Date) {
        let stems = album.tracks.map { stem(of: $0) }
        switch plan {
        case let .sending(fraction):
            let position = fraction * Double(stems.count)
            let finished = Int(position)
            for (index, stem) in stems.enumerated() {
                if index < finished {
                    ledger.markSending(stem: stem, fraction: 1)
                    ledger.markHandedOff(stem: stem, now: now)
                } else if index == finished {
                    ledger.markSending(stem: stem, fraction: position - Double(finished))
                } else {
                    ledger.abandonPreparation(stem: stem)
                }
            }
        case .preparing:
            for stem in stems.dropFirst(3) { ledger.abandonPreparation(stem: stem) }
        case .failed:
            for stem in stems {
                for _ in 0..<8 { ledger.markFailed(stem: stem, failure: .transient, now: now) }
            }
        case .synced, .notSynced, .partial, .queued:
            break
        }
    }

    private func recordRun(albums: [Album]) {
        runStems = []
        preparingStems = []
        for album in albums {
            for track in album.tracks {
                let stem = stem(of: track)
                guard let phase = ledger.phase(of: stem) else { continue }
                switch phase {
                case .preparing:
                    preparingStems.insert(stem)
                case .stuck:
                    continue
                default:
                    break
                }
                runStems.insert(stem)
                bytesByStem[stem] = WatchSyncSizing.estimatedBytes(for: track, profile: profile)
            }
        }
    }

    private func startDemoMetrics() {
        let now = Date()
        metrics.start(transferredBytes: 0, now: now.addingTimeInterval(-1))
        metrics.sample(transferredBytes: 2_600_000, remainingBytes: activeBytesRemaining, now: now)
    }
}

private extension Album {

    static func demoSubset(_ album: Album, tracks: [Track]) -> Album {
        Album(title: album.title, artist: album.artist, artwork: album.artwork, tracks: tracks, year: album.year, genre: album.genre)
    }
}
#endif
