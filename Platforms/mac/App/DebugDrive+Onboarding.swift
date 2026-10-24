import MidgarCore
#if DEBUG
import AppKit
import FlaccyCore

extension DebugDrive {

    /// Steps the interface scale through its whole range and back while a song
    /// plays, the way a held ⌘= does, and logs PASS if the window survives it.
    /// Clicks the welcome panel's two buttons the way a reviewer would and logs
    /// whether each click lands on its button and reaches its action. Run it on
    /// an empty library: an invisible view above the panel once took every click.
    static func exerciseOnboarding(window: NSWindow?) async {
        guard let window, let content = window.contentView, let frameView = content.superview else { return }
        func buttons(in view: NSView) -> [GlassCapsuleButton] {
            (view as? GlassCapsuleButton).map { [$0] } ?? view.subviews.flatMap(buttons(in:))
        }
        func report(_ expectation: String, _ passed: Bool) {
            MidgarLog.info("OnboardingExercise \(passed ? "PASS" : "FAIL"): \(expectation)", category: .general)
        }
        func chain(of view: NSView?) -> String {
            var names: [String] = []
            var current = view
            while let node = current, names.count < 8 {
                names.append(String(describing: type(of: node)))
                current = node.superview
            }
            return names.joined(separator: " < ")
        }
        func center(of button: GlassCapsuleButton) -> NSPoint {
            button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        }
        func click(_ button: GlassCapsuleButton) {
            window.makeKeyAndOrderFront(nil)
            let point = center(of: button)
            guard let target = frameView.hitTest(point) else { return }
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
                ) else { continue }
                if type == .leftMouseDown { target.mouseDown(with: event) } else { target.mouseUp(with: event) }
            }
        }
        func clickAndWatch(_ button: GlassCapsuleButton) async -> Bool {
            var fired = false
            let original = button.onClick
            button.onClick = {
                fired = true
                original?()
            }
            click(button)
            try? await Task.sleep(for: .milliseconds(800))
            button.onClick = original
            return fired
        }

        let titles = [String(localized: "Choose Music Folder…"), String(localized: "Download Sample Album")]
        var found: [GlassCapsuleButton] = []
        for _ in 0..<40 {
            found = buttons(in: content).filter { titles.contains($0.title) }
            if found.count == titles.count { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        try? await Task.sleep(for: .seconds(2))
        report("the welcome panel shows its two buttons (\(found.map(\.title)))", found.count == titles.count)
        for button in found {
            let hit = frameView.hitTest(center(of: button))
            let reachable = hit.map { $0 === button || $0.isDescendant(of: button) } ?? false
            report("a click on “\(button.title)” lands on the button: \(chain(of: hit))", reachable)
        }
        guard let choose = found.first(where: { $0.title == titles[0] }),
              let sample = found.first(where: { $0.title == titles[1] }) else { return }

        report("a click on Choose Music Folder… reaches its action", await clickAndWatch(choose))
        try? await Task.sleep(for: .seconds(1))
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
        try? await Task.sleep(for: .seconds(1))
        report("a click on Download Sample Album reaches its action", await clickAndWatch(sample))
    }

    static func exerciseZoom(window: NSWindow?) async {
        try? await Task.sleep(for: .seconds(6))
        let original = MacInterfaceScale.current
        MacInterfaceScale.set(MacInterfaceScale.standard)
        window?.setContentSize(NSSize(width: 1000, height: 640))
        try? await Task.sleep(for: .seconds(1))
        startHeroPlayback()
        try? await Task.sleep(for: .seconds(2))
        for _ in 0..<2 {
            NotificationCenter.default.post(name: .flaccyToggleNowPlaying, object: nil)
            try? await Task.sleep(for: .seconds(2))
            NotificationCenter.default.post(name: .flaccyToggleNowPlaying, object: nil)
            try? await Task.sleep(for: .seconds(1))
        }
        let steps = (0...10).map { MacInterfaceScale.standard + CGFloat($0) * MacInterfaceScale.step }
        for scale in steps + steps.reversed() {
            MacInterfaceScale.set(scale)
            try? await Task.sleep(for: .milliseconds(450))
        }
        MacInterfaceScale.set(original)
        AudioPlayer.shared.togglePlayPause()
        MidgarLog.info("DebugDrive: zoom exercise PASS — survived \(steps.count * 2) scale changes", category: .general)
    }

    static func startHeroPlayback() {
        let hero = Library.shared.albums.first { $0.title == "Parallax Hours" } ?? Library.shared.albums.first
        guard let hero, !hero.tracks.isEmpty else {
            MidgarLog.error("DebugDrive: no album available for hero playback", category: .general)
            return
        }
        AudioPlayer.shared.volume = 0.02
        let index = hero.tracks.firstIndex { $0.title == "Slow Machine" } ?? 0
        AudioPlayer.shared.play(hero.tracks, startingAt: index)
        AudioPlayer.shared.seek(to: 58)
    }

    /// Playback from the middle of the longest album on hand, so the queue panel
    /// has real history above the current track — the case where merely
    /// scrolling the row into view leaves it off the bottom of the panel.
    static func startDeepPlayback() {
        guard let album = Library.shared.albums.max(by: { $0.tracks.count < $1.tracks.count }),
              album.tracks.count > 4 else {
            startHeroPlayback()
            return
        }
        AudioPlayer.shared.volume = 0.02
        let last = CommandLine.arguments.contains("--deep-last")
        AudioPlayer.shared.play(album.tracks, startingAt: last ? album.tracks.count - 1 : album.tracks.count / 2)
        AudioPlayer.shared.seek(to: 45)
    }

    /// Captures the window's first sheet — the paywall, pair it with
    /// `--trial-day N` to render any day of the runway — through the same
    /// cached-display path the Stage B drive uses for sheets.
    static func captureSheet(of window: NSWindow?, name: String) {
        guard let sheet = window?.sheets.first else {
            MidgarLog.error("DebugDrive: no sheet to capture for \(name)", category: .general)
            return
        }
        sheet.contentView?.layoutSubtreeIfNeeded()
        sheet.displayIfNeeded()
        guard let data = windowServerPNG(sheet) ?? cachedDisplayPNG(sheet) else {
            MidgarLog.error("DebugDrive: sheet capture failed for \(name)", category: .general)
            return
        }
        let path = NSTemporaryDirectory() + name + ".png"
        do {
            try data.write(to: URL(fileURLWithPath: path))
            MidgarLog.info("DebugDrive: captured sheet to \(path)", category: .general)
        } catch {
            MidgarLog.error("DebugDrive: sheet capture write failed: \(error.localizedDescription)", category: .general)
        }
    }
}
#endif
