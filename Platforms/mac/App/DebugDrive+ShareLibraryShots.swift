import MidgarCore
#if DEBUG
import AppKit
import FlaccyServerEmbed
import FlaccyCore
import FlaccyEngine
import Foundation

/// The pictures of the Mac screens for Flaccy Server, taken after `DebugShareLibraryDrive` passed: the Servers pane with sharing on,
/// the Add a device sheet with its QR code, then, with `FLACCY_SHOT_SERVER=<url>|<code>` naming a second Flaccy Server, the Add
/// Flaccy Server sheet in its states, the Servers pane with the Sync row, the server's own screen and the merge summary. They land in the
/// app's temporary folder as `flaccy-shot-mac-*.png`; the log says `MAC SHARE SHOTS READY` at the end.
enum DebugShareLibraryShots {

    private static var seed: (address: String, code: String)? {
        let parts = (ProcessInfo.processInfo.environment["FLACCY_SHOT_SERVER"] ?? "").components(separatedBy: "|")
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    static func run(window: NSWindow?) async {
        guard let pane = await openServersPane() else {
            MidgarLog.error("MAC SHARE SHOTS FAILED: the Servers pane did not open", category: .sync)
            return
        }
        let settings = pane.view.window
        DebugDrive.capture(window: settings, name: "flaccy-shot-mac-servers-sharing")
        pane.presentAsSheet(AddDevicePanelViewController())
        try? await Task.sleep(for: .seconds(3))
        DebugDrive.captureSheet(of: settings, name: "flaccy-shot-mac-add-device")
        settings?.attachedSheet?.contentViewController?.dismiss(nil)
        try? await Task.sleep(for: .seconds(1))
        if let seed { await addFlaccyServer(seed, pane: pane) }
        MidgarLog.info("MAC SHARE SHOTS READY", category: .sync)
    }

    static func runIntro() async {
        guard let pane = await openServersPane() else {
            MidgarLog.error("MAC SHARE INTRO FAILED: the Servers pane did not open", category: .sync)
            return
        }
        let settings = pane.view.window
        let sharing = MacLibrarySharing.shared
        DebugDrive.capture(window: settings, name: "flaccy-shot-mac-share-off")
        pane.share.clickSwitchForCapture()
        try? await Task.sleep(for: .seconds(1))
        guard let sheet = settings?.attachedSheet, let share = button(titled: SharingCopy.share, in: sheet.contentView) else {
            MidgarLog.error("MAC SHARE INTRO FAILED: the first-run sheet did not appear", category: .sync)
            return
        }
        share.performClick(nil)
        do {
            try await DebugShareLibraryDrive.wait("the switch started sharing", seconds: 60) {
                if case .sharing = sharing.state { return true }
                return false
            }
        } catch {
            MidgarLog.error("MAC SHARE INTRO FAILED: \(sharing.state)", category: .sync)
            return
        }
        try? await Task.sleep(for: .seconds(2))
        DebugDrive.capture(window: settings, name: "flaccy-shot-mac-share-on-default-folder")
        pane.share.clickSwitchForCapture()
        do {
            try await DebugShareLibraryDrive.wait("the switch stopped sharing", seconds: 30) { sharing.state == .off }
        } catch {
            MidgarLog.error("MAC SHARE INTRO FAILED: still \(sharing.state) after the switch went off", category: .sync)
            return
        }
        MidgarLog.info("MAC SHARE INTRO PASSED: the first-run sheet, on and off from the switch (enabled now \(sharing.isEnabled))", category: .sync)
    }

    private static func button(titled title: String, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.lazy.compactMap { button(titled: title, in: $0) }.first
    }

    private static func openServersPane() async -> ServersSettingsPane? {
        (NSApp.delegate as? MacAppDelegate)?.showServersSettings()
        try? await Task.sleep(for: .seconds(3))
        let settings = NSApp.windows.first { $0.contentViewController is SettingsTabViewController }
        let tabs = settings?.contentViewController as? SettingsTabViewController
        return tabs?.tabViewItems.compactMap { $0.viewController as? ServersSettingsPane }.first
    }

    private static func addFlaccyServer(_ seed: (address: String, code: String), pane: ServersSettingsPane) async {
        let settings = pane.view.window
        try? await ServerSyncService.engine.disconnect()
        pane.presentAddFlaccyServer(link: nil)
        try? await Task.sleep(for: .seconds(2))
        guard let panel = settings?.attachedSheet?.contentViewController as? AddFlaccyServerPanelViewController else { return }
        DebugDrive.captureSheet(of: settings, name: "flaccy-shot-mac-add-flaccy-idle")
        panel.fill(address: seed.address, code: "0000-0000-0000-0000-0000-00")
        try? await Task.sleep(for: .seconds(1))
        DebugDrive.captureSheet(of: settings, name: "flaccy-shot-mac-add-flaccy-filled")
        await panel.connectForCapture()
        try? await Task.sleep(for: .seconds(1))
        DebugDrive.captureSheet(of: settings, name: "flaccy-shot-mac-add-flaccy-wrong-code")
        panel.fill(address: seed.address, code: seed.code)
        await panel.connectForCapture()
        try? await Task.sleep(for: .seconds(1))
        DebugDrive.captureSheet(of: settings, name: "flaccy-shot-mac-add-flaccy-connected")
        panel.dismiss(nil)
        await settle()
        await showMergeSummary(settings)
        DebugDrive.capture(window: settings, name: "flaccy-shot-mac-servers-sync")
        guard let row = pane.model.rows.first(where: { $0.flaccy != nil }) else { return }
        pane.showDetails(of: row)
        try? await Task.sleep(for: .seconds(3))
        DebugDrive.captureSheet(of: settings, name: "flaccy-shot-mac-server-detail")
        settings?.attachedSheet?.contentViewController?.dismiss(nil)
    }

    private static func settle() async {
        try? await DebugShareLibraryDrive.wait("the first sync with the second server settled", seconds: 120) {
            if case .upToDate = FlaccyServerStatusStore.shared.status { return FlaccyServerLibrary.record() != nil }
            return false
        }
        try? await Task.sleep(for: .seconds(2))
    }

    private static func showMergeSummary(_ settings: NSWindow?) async {
        do {
            try await DebugShareLibraryDrive.wait("the merge summary appeared", seconds: 60) {
                settings?.attachedSheet?.contentViewController is ServerMergeSummaryPanelViewController
            }
        } catch {
            MidgarLog.error("MAC SHARE SHOTS: the engine reported no merge; showing a made-up summary for the picture", category: .sync)
            var report = ServerMergeReport()
            report.playlistNames = [DebugShareLibraryDrive.playlistName]
            report.lovesAdded = 2
            if let summary = ServerMergeSummary(report) {
                settings?.contentViewController?.presentAsSheet(ServerMergeSummaryPanelViewController(summary: summary))
            }
        }
        try? await Task.sleep(for: .seconds(1))
        DebugDrive.captureSheet(of: settings, name: "flaccy-shot-mac-merge-summary")
        settings?.attachedSheet?.contentViewController?.dismiss(nil)
        try? await Task.sleep(for: .seconds(1))
    }
}
#endif
