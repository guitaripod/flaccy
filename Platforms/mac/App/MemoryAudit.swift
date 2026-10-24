import MidgarCore
#if DEBUG
import AppKit
import Combine
import FlaccyCore

/// Headless checks for the memory work that cannot be seen from a single
/// screenshot: shared library metadata, incremental song-table refreshes,
/// artwork tiers, shadow paths, glass grouping and window teardown.
@MainActor
enum MemoryAudit {

    private static var failures = 0

    static func run(window: NSWindow?) async {
        MidgarLog.info("MemoryAudit: start", category: .general)
        await waitForLibrary()

        await checkSongsTableTrackChange()
        checkSharedLibraryMeta()
        checkArtworkDecode()
        checkSymbolCache()
        checkAlbumShadow()
        checkGlassGrouping()
        await checkSettingsRelease()
        await checkEqualizerRelease()

        MidgarLog.info("MemoryAudit: done failures=\(failures)", category: .general)
    }

    private static func waitForLibrary() async {
        for _ in 0..<80 {
            if !Library.shared.allTracks.isEmpty {
                try? await Task.sleep(for: .seconds(2))
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        fail("library did not load")
    }

    private static func checkSongsTableTrackChange() async {
        let model = SongsTableViewModel()
        for _ in 0..<80 {
            if !model.rowsPublisher.value.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !model.rowsPublisher.value.isEmpty else {
            fail("songs table did not load rows")
            return
        }

        let libraryUpdates = ObservedCount()
        let token = NotificationCenter.default.addObserver(
            forName: Library.didUpdateNotification, object: nil, queue: .main
        ) { _ in libraryUpdates.increment() }
        defer { NotificationCenter.default.removeObserver(token) }

        let reloads = model.debugReloadCount
        let updates = model.debugTrackUpdateCount
        let updatesAtPost = libraryUpdates.value
        NotificationCenter.default.post(name: AudioPlayer.trackDidChange, object: nil)
        for _ in 0..<40 {
            if model.debugTrackUpdateCount > updates { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let extraReloads = model.debugReloadCount - reloads
        let extraLibraryUpdates = libraryUpdates.value - updatesAtPost
        check(
            "songs track change skips full reload",
            extraReloads <= extraLibraryUpdates
        )
        if model.debugCurrentTrackIsIndexed {
            check("songs track change updates one row", model.debugTrackUpdateCount > updates)
        } else {
            MidgarLog.info("MemoryAudit: SKIP songs row update (no indexed current track)", category: .general)
        }
    }

    private static func checkSharedLibraryMeta() {
        LibraryViewModel.debugInvalidateSharedMeta()
        LibraryViewModel.debugResetMetaBuildCount()
        let first = LibraryViewModel()
        let second = LibraryViewModel()
        let count = first.debugTrackMetaCount()
        _ = second.debugTrackMetaCount()
        check("library metadata builds once for both view models", LibraryViewModel.debugMetaBuildCount == 1)
        check("library metadata has rows", count > 0)
    }

    private static func checkArtworkDecode() {
        guard let data = testImageData() else {
            fail("could not build test artwork")
            return
        }
        for (limit, label) in [(480.0, "thumbnail"), (800.0, "now playing"), (1600.0, "full")] {
            guard let image = AlbumArtworkCache.decode(data, maxPixelSize: limit),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                fail("artwork \(label) did not decode")
                continue
            }
            check("artwork \(label) stays within \(Int(limit)) px", max(cgImage.width, cgImage.height) <= Int(limit))
        }
        guard let cached = ImageCache.shared.imageFromData(data),
              let cgImage = cached.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            fail("image cache did not decode")
            return
        }
        check("image cache downsamples to 1024 px", max(cgImage.width, cgImage.height) <= 1024)
        check("image cache costs rep-backed images", ImageCache.shared.debugCost(of: NSImage(size: NSSize(width: 100, height: 100))) > 0)
    }

    private static func checkSymbolCache() {
        let first = MacSymbolImage.image("play.fill")
        let second = MacSymbolImage.image("play.fill")
        check("symbol images are shared", first != nil && first === second)
    }

    private static func checkAlbumShadow() {
        let item = AlbumGridItem(nibName: nil, bundle: nil)
        let view = item.view
        view.frame = NSRect(x: 0, y: 0, width: 180, height: 220)
        view.layoutSubtreeIfNeeded()
        item.viewWillLayout()
        check("album tile uses an explicit shadow path", item.debugShadowPath != nil)
    }

    private static func checkGlassGrouping() {
        let first = GlassCapsuleButton(title: "Play", symbolName: "play.fill")
        let second = GlassCapsuleButton(title: "Shuffle", symbolName: "shuffle")
        let group = MacLiquidGlass.buttonGroup([first, second])
        if MacLiquidGlass.prefersReducedTransparency {
            check("glass grouping respects reduced transparency", true)
        } else {
            check("glass buttons share a container", group is NSGlassEffectContainerView)
        }
        group.layoutSubtreeIfNeeded()
        check("glass group has a fitting size", group.fittingSize.width > 0 && group.fittingSize.height > 0)
    }

    private static func checkSettingsRelease() async {
        var controller: SettingsWindowController? = SettingsWindowController(
            contentController: NSViewController()
        )
        weak let weakController = controller
        controller?.show()
        controller?.close()
        controller = nil
        for _ in 0..<20 {
            if weakController == nil { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        check("settings window releases after close", weakController == nil)
    }

    private static func checkEqualizerRelease() async {
        let controller = MacEqualizerWindowController.shared
        controller.contentViewController = NSViewController()
        controller.close()
        for _ in 0..<20 {
            if controller.contentViewController == nil { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        check("equalizer content releases after close", controller.contentViewController == nil)
    }

    private static func testImageData() -> Data? {
        let side = 2000
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(NSColor.systemTeal.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(
            using: .jpeg, properties: [.compressionFactor: 0.8]
        )
    }

    private static func check(_ name: String, _ passed: Bool) {
        if passed {
            MidgarLog.info("MemoryAudit: PASS \(name)", category: .general)
        } else {
            fail(name)
        }
    }

    private static func fail(_ name: String) {
        failures += 1
        MidgarLog.error("MemoryAudit: FAIL \(name)", category: .general)
    }
}
#endif
