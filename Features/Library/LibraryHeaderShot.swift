#if DEBUG
import MidgarCore
import UIKit

/// DEBUG self-capture of the Library's header, for a device no screenshot tool
/// or UI test reaches (iOS 18 on the iPhone XS). With `--shot-library-header`
/// the app opens the Library's songs and writes three pictures of its own window to
/// `tmp/header-shot/`: the list at its top, the list after a jump from the A-Z index
/// (under the shown header), and the header collapsed. It logs `HEADER SHOT
/// DONE` when the jump held and `HEADER SHOT FAILED` when the list fell back
/// to its top.
@MainActor
enum LibraryHeaderShot {

    static func runIfRequested(tabs: AppTabBarController) {
        guard CommandLine.arguments.contains("--shot-library-header") else { return }
        Task {
            tabs.showLibrary(.songs)
            try? await Task.sleep(for: .seconds(6))
            let library = tabs.library
            guard let window = library.view.window, let list = library.collectionView else {
                MidgarLog.error("HEADER SHOT FAILED: the Library is not in a window", category: .ui)
                return
            }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("header-shot", isDirectory: true)
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            write(window, to: folder, named: "rest")
            library.sectionIndexView.onSelectIndex?("M")
            try? await Task.sleep(for: .seconds(1))
            let travelled = list.contentOffset.y + list.adjustedContentInset.top
            let landing = landingGap(of: "M", in: library)
            write(window, to: folder, named: "under")
            library.header.collapseForCapture()
            library.view.layoutIfNeeded()
            try? await Task.sleep(for: .seconds(1))
            write(window, to: folder, named: "collapsed")
            if travelled > 200, let landing, (-1...40).contains(landing) {
                MidgarLog.info("HEADER SHOT DONE: the index jump held \(Int(travelled)) pt down, its row \(Int(landing)) pt under the header", category: .ui)
            } else {
                MidgarLog.error(
                    "HEADER SHOT FAILED: the index jump is \(Int(travelled)) pt from the top, its row \(landing.map { "\(Int($0)) pt under the header" } ?? "not on screen")",
                    category: .ui
                )
            }
        }
    }

    /// How far below the header's bottom edge the first row of `letter` starts, or nil when that row is not on screen.
    private static func landingGap(of letter: String, in library: LibraryViewController) -> CGFloat? {
        guard let item = library.viewModel.indexOfFirstItem(forLetter: letter),
              let cell = library.collectionView.cellForItem(at: IndexPath(item: item, section: 0)) else { return nil }
        let row = cell.convert(cell.bounds, to: library.view)
        return row.minY - library.header.frame.maxY
    }

    private static func write(_ window: UIWindow, to folder: URL, named name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        do {
            try image.pngData()?.write(to: folder.appendingPathComponent("\(name).png"))
        } catch {
            MidgarLog.error("HEADER SHOT FAILED: \(name) not written: \(error.localizedDescription)", category: .ui)
        }
    }
}
#endif
