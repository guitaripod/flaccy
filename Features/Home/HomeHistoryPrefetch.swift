import FlaccyEngine
import Foundation

/// Reads Home's history as the app launches, while the library a previous
/// launch indexed is still coming back, so the first frame is built from rows
/// already in hand instead of queueing behind the scan's writes for them.
/// Shared by the iPhone, iPad and Mac Homes.
@MainActor
final class HomeHistoryPrefetch {

    /// How old the prefetched rows may be and still stand for the first frame.
    nonisolated static let freshness: TimeInterval = 20

    private var task: Task<HomeHistoryRows, Never>?

    func start() {
        guard task == nil else { return }
        let now = Date()
        let calendar = Calendar.current
        task = Task.detached(priority: .userInitiated) {
            HomeFeedBuilder.readHistory(now: now, calendar: calendar)
        }
    }

    /// Hands the read over once, for the first frame; later builds read their own.
    func claim() -> Task<HomeHistoryRows, Never>? {
        defer { task = nil }
        return task
    }

    /// The claimed rows when they are still recent enough to stand for a build at `now`.
    nonisolated static func rows(_ claimed: Task<HomeHistoryRows, Never>?, at now: Date) async -> HomeHistoryRows? {
        guard let rows = await claimed?.value, now.timeIntervalSince(rows.readAt) < freshness else { return nil }
        return rows
    }
}
