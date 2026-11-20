#if DEBUG && os(iOS)
import MidgarCore
import UIKit

/// Walks an iPad's Now Playing column over whatever the device already has in its queue, with no
/// touch, no seeded data and no playback started: puts the sidebar away to the top bar, gives the
/// column the turn, opens lyrics inside it, spreads it over the window and brings it back, then the
/// queue, and logs what each step left on screen. `COLUMN EXERCISE PASSED` when the library stayed
/// beside lyrics and the queue and only the spread hid it, `COLUMN EXERCISE FAILED` otherwise,
/// `COLUMN EXERCISE SKIPPED` when nothing is queued or the window has no room for the column.
/// The column setting and the sidebar are put back as they were.
///
/// Launch with `--exercise-column`; `FLACCY_COLUMN_STEP` sets the seconds between steps (4 by
/// default), time enough for `devicectl device capture` to take each one.
@MainActor
enum ColumnExercise {

    static let launchArgument = "--exercise-column"

    static func runIfRequested(tabs: AppTabBarController, player: PlayerContainerViewController) {
        guard CommandLine.arguments.contains(launchArgument) else { return }
        Task { await run(tabs: tabs, player: player) }
    }

    private static var step: Duration {
        .seconds(Double(ProcessInfo.processInfo.environment["FLACCY_COLUMN_STEP"] ?? "") ?? 4)
    }

    private static func run(tabs: AppTabBarController, player: PlayerContainerViewController) async {
        guard await waitForQueue(), let root = tabs.parent as? RootContainerViewController else {
            MidgarLog.info("COLUMN EXERCISE SKIPPED: nothing in the queue", category: .ui)
            return
        }
        try? await Task.sleep(for: .seconds(2))
        guard root.canShowPlayerColumn else {
            MidgarLog.info("COLUMN EXERCISE SKIPPED: a \(root.view.bounds.size) window has no room for the column", category: .ui)
            return
        }
        let columnWasShown = PlayerColumnSetting.isShown
        let sidebarWasHidden = tabs.sidebar.isHidden
        var failures: [String] = []

        tabs.sidebar.isHidden = true
        try? await Task.sleep(for: .seconds(1))
        root.giveColumnTheTurn()
        try? await Task.sleep(for: step)
        check("column beside the library", root.showsPlayerColumn && !tabs.view.isHidden, into: &failures)

        player.toggleCenterState(.lyrics)
        try? await Task.sleep(for: step)
        check(
            "lyrics inside the column, library beside",
            player.centerState == .lyrics && !player.isSpread && root.showsPlayerColumn && !tabs.view.isHidden,
            into: &failures)

        player.toggleFullPlayer()
        try? await Task.sleep(for: step)
        check("spread over the window", player.isSpread && tabs.view.isHidden, into: &failures)

        player.toggleFullPlayer()
        try? await Task.sleep(for: step)
        check("back beside the library", !player.isSpread && !tabs.view.isHidden, into: &failures)

        player.toggleCenterState(.queue)
        try? await Task.sleep(for: step)
        check(
            "queue inside the column, library beside",
            player.centerState == .queue && !player.isSpread && !tabs.view.isHidden, into: &failures)

        player.toggleCenterState(.queue)
        PlayerColumnSetting.setShown(columnWasShown)
        tabs.sidebar.isHidden = sidebarWasHidden
        if failures.isEmpty {
            MidgarLog.info("COLUMN EXERCISE PASSED in a \(root.view.bounds.size) window", category: .ui)
        } else {
            MidgarLog.error("COLUMN EXERCISE FAILED: \(failures.joined(separator: "; "))", category: .ui)
        }
    }

    private static func check(_ name: String, _ holds: Bool, into failures: inout [String]) {
        MidgarLog.info("Column exercise: \(name) \(holds ? "holds" : "does not hold")", category: .ui)
        if !holds { failures.append(name) }
    }

    private static func waitForQueue() async -> Bool {
        for _ in 0..<120 {
            if AudioPlayer.shared.currentTrack != nil, !Library.shared.isLoading { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }
}
#endif
