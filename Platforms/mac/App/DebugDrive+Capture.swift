import MidgarCore
#if DEBUG
import AppKit
import FlaccyCore

extension DebugDrive {

    /// Drives the equalizer deck's pointer callbacks through the screen's real
    /// timing and logs PASS/FAIL per expectation: a pointer that rests plays a
    /// preset, a sweep switches at once, leaving ends it after the grace, and a
    /// click keeps one as a single undo step.
    static func exerciseDeck(_ screen: MacEqualizerViewController, engine: EqualizerEngine) async {
        func report(_ expectation: String, _ passed: Bool) {
            MidgarLog.info("DeckExercise \(passed ? "PASS" : "FAIL"): \(expectation)", category: .general)
        }
        let treble = EqualizerPresets.id(forKey: "trebleBoost")
        let vocal = EqualizerPresets.id(forKey: "vocal")
        let bass = EqualizerPresets.id(forKey: "bassBoost")
        let inForce = engine.profileInForce.id
        screen.exercisePointer(at: treble)
        try? await Task.sleep(for: .milliseconds(30))
        report("a pointer that has not rested 90 ms plays nothing yet", screen.auditionedPresetID == nil)
        try? await Task.sleep(for: .milliseconds(200))
        report("after resting it plays the preset, the engine auditions it and the curve previews", screen.auditionedPresetID == treble && engine.auditioned?.id == treble && screen.curveIsPreviewing)
        report("auditioning leaves the saved profile alone", engine.profileInForce.id == inForce)
        screen.exercisePointer(at: vocal)
        report("while one plays the next switches at once", screen.auditionedPresetID == vocal && engine.auditioned?.id == vocal)
        screen.exercisePointer(at: nil)
        try? await Task.sleep(for: .milliseconds(60))
        report("the preview survives inside the 160 ms leave grace", screen.auditionedPresetID == vocal)
        screen.exercisePointer(at: bass)
        try? await Task.sleep(for: .milliseconds(250))
        report("entering another preset inside the grace cancels the end", screen.auditionedPresetID == bass)
        screen.exercisePointer(at: nil)
        try? await Task.sleep(for: .milliseconds(300))
        report("leaving the deck puts back what was playing", screen.auditionedPresetID == nil && engine.auditioned == nil && !screen.curveIsPreviewing && engine.profileInForce.id == inForce)
        screen.exercisePointer(at: bass)
        try? await Task.sleep(for: .milliseconds(200))
        screen.exerciseKeep(bass)
        report("clicking keeps the preset and ends the audition", engine.profileInForce.id == bass && engine.auditioned == nil && screen.auditionedPresetID == nil)
        controllerUndo(screen)?.undo()
        report("one undo puts back the previous profile", engine.profileInForce.id == inForce)
    }

    static func controllerUndo(_ screen: MacEqualizerViewController) -> UndoManager? {
        screen.view.window?.undoManager
    }

    static func capture(window: NSWindow?, name: String) {
        if let window {
            MidgarLog.info(
                "DebugDrive: capture \(name) — frame \(window.frame), screen \(window.screen?.frame ?? .zero), backingScale \(window.backingScaleFactor)",
                category: .general
            )
        }
        if let root = window?.contentViewController as? RootContainerViewController {
            let sidebar = root.splitViewController.sidebarViewController
            MidgarLog.info("DebugDrive: sidebar renders \(sidebar.visibleRowCount) rows", category: .general)
        }
        if let contentView = window?.contentView,
           let tree = contentView.perform(NSSelectorFromString("_subtreeDescription"))?.takeUnretainedValue() as? String {
            let treePath = NSTemporaryDirectory() + "flaccy-viewtree.txt"
            try? tree.write(to: URL(fileURLWithPath: treePath), atomically: true, encoding: .utf8)
            MidgarLog.info("DebugDrive: view tree dumped to \(treePath)", category: .general)
        }
        guard let data = windowServerPNG(window) ?? cachedDisplayPNG(window) else {
            MidgarLog.error("DebugDrive: no capture path produced an image", category: .general)
            return
        }
        let path = NSTemporaryDirectory() + name + ".png"
        do {
            try data.write(to: URL(fileURLWithPath: path))
            MidgarLog.info("DebugDrive: captured window to \(path)", category: .general)
        } catch {
            MidgarLog.error("DebugDrive: window capture failed: \(error.localizedDescription)", category: .general)
        }
    }

    typealias SLSMainConnectionIDFunc = @convention(c) () -> Int32
    typealias SLSHWCaptureWindowListFunc = @convention(c) (
        Int32, UnsafeMutablePointer<UInt32>, Int32, UInt32
    ) -> Unmanaged<CFArray>?

    /// Captures the window as composited by WindowServer (glass, vibrancy and
    /// shadows render for real), which works without Screen Recording TCC for
    /// windows the process itself owns. Uses SkyLight SPI, which is fine here:
    /// this is a DEBUG-only screenshot rig that never ships in Release.
    static func windowServerPNG(_ window: NSWindow?) -> Data? {
        guard let window, window.windowNumber > 0,
              let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let connectionSymbol = dlsym(skyLight, "SLSMainConnectionID"),
              let captureSymbol = dlsym(skyLight, "SLSHWCaptureWindowList")
        else { return nil }
        let mainConnection = unsafeBitCast(connectionSymbol, to: SLSMainConnectionIDFunc.self)
        let captureWindows = unsafeBitCast(captureSymbol, to: SLSHWCaptureWindowListFunc.self)
        var windowID = UInt32(window.windowNumber)
        let ignoreClipShapeAndBestResolution: UInt32 = (1 << 11) | (1 << 8)
        guard let images = captureWindows(
                  mainConnection(), &windowID, 1, ignoreClipShapeAndBestResolution
              )?.takeRetainedValue() as? [CGImage],
              let image = images.first, image.width > 1
        else {
            MidgarLog.error("DebugDrive: WindowServer capture unavailable, falling back to cacheDisplay", category: .general)
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    static func cachedDisplayPNG(_ window: NSWindow?) -> Data? {
        guard let view = window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
#endif
