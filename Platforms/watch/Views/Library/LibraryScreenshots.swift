import FlaccyCore
import SwiftUI

/// Simulator-only launch flags for the browsing screens; every member is inert
/// on a device. `--shot-receiving` and `--shot-preparing` stage a transfer,
/// `--shot-stage` only reports storage, `--shot-storage` and `--shot-artists` open those screens with a believable
/// storage figure, and `--shot-empty` draws the empty library without touching
/// the data. Marketing frames use only the seeded fictional catalog.
enum LibraryShots {

    static var forcesEmptyLibrary: Bool { has("--shot-empty") }

    /// `--shot-scroll albums|end` scrolls the library to a landmark, because the
    /// simulator cannot turn the Digital Crown from the command line.
    static var scrollTarget: String? {
        #if targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--shot-scroll"), flag + 1 < arguments.count else { return nil }
        return arguments[flag + 1]
        #else
        nil
        #endif
    }

    /// `--shot-scroll <landmark>[:<y>]` names a row to scroll to and,
    /// optionally, how far down the screen (0 top, 1 bottom) it should land, so
    /// a landmark can clear the navigation bar's blur. Landmarks: `albums`,
    /// `end`, `upnext` (the queue's heading), `tracks` (an album's first song)
    /// and `firstalbum`.
    static func landmark(for target: String) -> (id: String, anchor: UnitPoint?) {
        let parts = target.split(separator: ":", maxSplits: 1).map(String.init)
        let fraction = parts.count == 2 ? Double(parts[1]) : nil
        return (parts[0], fraction.map { UnitPoint(x: 0.5, y: $0) })
    }

    /// `--shot-remove <album>` raises that row's removal dialog, and
    /// `--shot-remove-yes` then answers it, so the whole removal can be watched.
    static var removalTarget: String? {
        #if targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--shot-remove"), flag + 1 < arguments.count else { return nil }
        return arguments[flag + 1]
        #else
        nil
        #endif
    }

    static var confirmsRemoval: Bool { has("--shot-remove-yes") }

    @MainActor
    static func run(status: WatchSyncStatus, store: WatchLibraryStore, path: Binding<NavigationPath>) async {
        #if targetEnvironment(simulator)
        guard stagesAnything else { return }
        for _ in 0..<50 where store.albums.isEmpty {
            try? await Task.sleep(for: .milliseconds(200))
        }
        try? await Task.sleep(for: .seconds(1.5))
        stage(status)
        if has("--shot-artists") { path.wrappedValue.append(Route.artists) }
        if has("--shot-storage") { path.wrappedValue.append(Route.storage) }
        await keepStaged(status)
        #endif
    }

    #if targetEnvironment(simulator)
    private static var stagesAnything: Bool {
        ["--shot-receiving", "--shot-preparing", "--shot-storage", "--shot-artists", "--shot-stage"].contains(where: has)
    }

    /// The receiver reports the host Mac's real disk on every heartbeat, which
    /// would overwrite the staged figure a moment later; restating it for half a
    /// minute keeps a screenshot honest to the flag.
    @MainActor
    private static func keepStaged(_ status: WatchSyncStatus) async {
        for _ in 0..<30 {
            try? await Task.sleep(for: .seconds(1))
            stage(status)
        }
    }

    /// 2.4 GB of music on a 32 GB watch with 18 GB free: the figure the store
    /// screenshots quote.
    @MainActor
    private static func stage(_ status: WatchSyncStatus) {
        if has("--shot-receiving") { status.apply(batch: SyncBatch(total: 12, remaining: 9, preparing: false)) }
        if has("--shot-preparing") { status.apply(batch: SyncBatch(total: 12, remaining: 12, preparing: true)) }
        status.apply(storage: WatchStorage(usedBytes: 2_400_000_000, freeBytes: 18_000_000_000, totalBytes: 32_000_000_000))
    }
    #endif

    private static func has(_ flag: String) -> Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains(flag)
        #else
        false
        #endif
    }
}

extension View {

    /// Simulator-only: after the screen has laid out, jumps to the landmark
    /// named by `--shot-scroll`. Absent the flag it does nothing, on any device.
    func screenshotScroll(anchor: UnitPoint = .top) -> some View {
        ScrollViewReader { proxy in
            self.task {
                guard let target = LibraryShots.scrollTarget else { return }
                let landmark = LibraryShots.landmark(for: target)
                try? await Task.sleep(for: .seconds(3))
                proxy.scrollTo(landmark.id, anchor: landmark.anchor ?? anchor)
            }
        }
    }
}
