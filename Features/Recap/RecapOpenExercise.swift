#if DEBUG && os(iOS)
import MidgarCore
import QuartzCore
import UIKit

/// Opens the Recap tab for the first time over whatever library and history are on the device,
/// the way a tap on the tab does, and times the main thread through it. UIKit can load the tab's
/// view on its own a few seconds after launch, so the frame gaps are measured from whichever comes
/// first, that load or the tap, until the Recap has drawn its content and settled. Logs how long
/// the selection held the main thread, the longest frame gap, and how long the content took after
/// the view loaded and after the tap: `RECAP OPEN PASSED` when no frame stalls longer than
/// `stallBudget`, `RECAP OPEN FAILED` otherwise.
///
/// Launch with `--exercise-recap-open`; the library is left to settle first.
@MainActor
enum RecapOpenExercise {

    static let launchArgument = "--exercise-recap-open"

    private static let stallBudget: CFTimeInterval = 0.1
    private static let settleWindow: CFTimeInterval = 4
    private static let contentTimeout: CFTimeInterval = 15

    static func runIfRequested(tabs: AppTabBarController) {
        guard CommandLine.arguments.contains(launchArgument) else { return }
        Task { await run(tabs: tabs) }
    }

    private static func run(tabs: AppTabBarController) async {
        let recorder = FrameGapRecorder { tabs.recapController.isViewLoaded }
        recorder.start()
        await waitForSettledLibrary()
        try? await Task.sleep(for: .seconds(3))
        MidgarLog.info(
            "RecapOpen: \(Library.shared.albums.count) albums, \(Library.shared.allTracks.count) tracks",
            category: .performance
        )

        let tapped = CACurrentMediaTime()
        tabs.show(.recap)
        let selection = CACurrentMediaTime() - tapped

        var contentShown: CFTimeInterval?
        while CACurrentMediaTime() - tapped < contentTimeout {
            if contentShown == nil, isShowingContent(tabs.recapController.view) {
                contentShown = CACurrentMediaTime() - tapped
            }
            if let contentShown, CACurrentMediaTime() - tapped > contentShown + settleWindow { break }
            try? await Task.sleep(for: .milliseconds(16))
        }
        recorder.stop()

        let loaded = min(recorder.watchedSince ?? tapped, tapped)
        let gaps = recorder.gaps(after: loaded)
        let longest = gaps.map(\.length).max() ?? 0
        let hitches = gaps.filter { $0.length > 0.05 }
        let hitchTimes = hitches.map { "\(milliseconds($0.length)) ms at \(milliseconds($0.endedAt - tapped)) ms" }
        let loadedBy = loaded < tapped ? "by UIKit \(milliseconds(tapped - loaded)) ms before the tap" : "by the tap"
        let content = contentShown.map {
            "content \(milliseconds($0)) ms after the tap, \(milliseconds(tapped - loaded + $0)) ms after the view loaded"
        } ?? "no content"
        let summary = "view loaded \(loadedBy), selection held main \(milliseconds(selection)) ms, "
            + "longest frame gap since the load \(milliseconds(longest)) ms, \(hitches.count) frames over 50 ms "
            + "[\(hitchTimes.joined(separator: ", "))], \(content)"
        let passed = longest < stallBudget && contentShown != nil
        MidgarLog.info("RECAP OPEN \(passed ? "PASSED" : "FAILED"): \(summary)", category: .performance)
    }

    /// The Recap counts as shown once its collection view is visible and holds sections, which
    /// happens only after the skeleton has handed over.
    private static func isShowingContent(_ root: UIView) -> Bool {
        guard let collection = firstCollectionView(in: root) else { return false }
        return collection.alpha > 0.99 && collection.numberOfSections > 0
    }

    private static func firstCollectionView(in view: UIView) -> UICollectionView? {
        if let collection = view as? UICollectionView { return collection }
        for subview in view.subviews {
            if let found = firstCollectionView(in: subview) { return found }
        }
        return nil
    }

    private static func waitForSettledLibrary() async {
        var quietTicks = 0
        for _ in 0..<360 {
            let busy = Library.shared.isLoading || Library.shared.albums.isEmpty
            quietTicks = busy ? 0 : quietTicks + 1
            if quietTicks >= 4 { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
        MidgarLog.error("RecapOpen: the library never settled", category: .performance)
    }

    private static func milliseconds(_ seconds: CFTimeInterval) -> Int {
        Int((seconds * 1000).rounded())
    }
}

/// Records the time of every display refresh the main thread services, so a gap between two
/// of them is a frame the main thread was too busy to draw, and notes the last refresh before
/// `watched` first held, so the frame in which it turned true counts.
@MainActor
private final class FrameGapRecorder: NSObject {

    private(set) var watchedSince: CFTimeInterval?
    private let watched: () -> Bool
    private var link: CADisplayLink?
    private var stamps: [CFTimeInterval] = []

    init(watching watched: @escaping () -> Bool) {
        self.watched = watched
    }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    /// Each frame gap after `start`, with the time of the refresh that ended it.
    func gaps(after start: CFTimeInterval) -> [(length: CFTimeInterval, endedAt: CFTimeInterval)] {
        let lastBefore = stamps.last { $0 <= start } ?? start
        let window = [lastBefore] + stamps.filter { $0 > start }
        return zip(window.dropFirst(), window).map { (length: $0 - $1, endedAt: $0) }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if watchedSince == nil, watched() { watchedSince = stamps.last ?? now }
        stamps.append(now)
    }
}
#endif
