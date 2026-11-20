import MidgarCore
#if DEBUG
import FlaccyCore
import FlaccyEngine
import UIKit

/// Opens the Flaccy Server screens for a picture, or drives the whole Add sheet unattended on a real phone.
///
/// Launch with `--shot-flaccy-server <scenario>` and `FLACCY_SHOT_SERVER=<url>|<code>`, where the scenario is `idle`, `filled`,
/// `checking`, `wrong-code`, `unreachable`, `connected`, `servers`, `detail`, `love-two`, `merge`, `move-offer` (the offer to play the
/// songs on this device from the server, as it opens after the first sync) or `move-done` (that offer accepted, with loved songs kept). The driver logs `SERVER SHOT READY: <scenario>`
/// once the screen is on display. Launch with `--drive-flaccy-server` and a `flaccy://server` link (a URL payload, or `FLACCY_DRIVE_LINK` where the system asks before opening one) to have the Add sheet that
/// the link opens press Connect by itself, then log what the connection did.
@MainActor
enum FlaccyServerShot {

    static let argument = "--shot-flaccy-server"
    static let environmentKey = "FLACCY_SHOT_SERVER"
    static let driveArgument = "--drive-flaccy-server"

    static var drivesConnect: Bool {
        CommandLine.arguments.contains(driveArgument)
    }

    private static var scenario: String? {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: argument) else { return nil }
        return flag + 1 < arguments.count ? arguments[flag + 1] : "idle"
    }

    private static var seed: (address: String, code: String)? {
        let parts = (ProcessInfo.processInfo.environment[environmentKey] ?? "").components(separatedBy: "|")
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    static let driveLinkKey = "FLACCY_DRIVE_LINK"

    static var driveLink: URL? {
        ProcessInfo.processInfo.environment[driveLinkKey].flatMap { URL(string: $0) }
    }

    static func runIfRequested(tabs: AppTabBarController) {
        if CommandLine.arguments.contains("--skip-keychain") { RemoteCredentialStore.shared.useMemoryBackend() }
        guard let scenario else { return }
        Task {
            try? await Task.sleep(for: .seconds(3))
            tabs.show(.library)
            await present(scenario, nav: tabs.libraryNavigation)
        }
    }

    private static func present(_ scenario: String, nav: UINavigationController) async {
        let model = AddFlaccyServerViewModel()
        switch scenario {
        case "idle":
            show(model, on: nav)
        case "filled":
            fill(model, code: seed?.code)
            show(model, on: nav)
        case "checking":
            model.address = "100.64.0.9"
            model.code = seed?.code ?? "ABCD-EFGH"
            show(model, on: nav)
            Task { await model.connect() }
            try? await Task.sleep(for: .seconds(1.5))
        case "wrong-code":
            fill(model, code: "0000-0000-0000-0000-0000-00")
            show(model, on: nav)
            await model.connect()
        case "unreachable":
            model.address = "100.64.0.9"
            model.code = seed?.code ?? "ABCD-EFGH"
            show(model, on: nav)
            await model.connect()
        case "connected":
            fill(model, code: seed?.code)
            show(model, on: nav)
            await model.connect()
            try? await Task.sleep(for: .seconds(1))
        case "love-two":
            fill(model, code: seed?.code)
            await model.connect()
            await waitForSync()
            loveTwoSongs()
            try? await Task.sleep(for: .seconds(8))
        case "merge":
            fill(model, code: seed?.code)
            show(model, on: nav)
            await model.connect()
            await waitForMergeSummary(on: nav)
        case "servers", "detail":
            fill(model, code: seed?.code)
            await model.connect()
            await waitForSync()
            await dismissMoveOffer(on: nav)
            await open(scenario, nav: nav)
        case "move-offer", "move-done":
            fill(model, code: seed?.code)
            await model.connect()
            guard await waitForMoveOffer(on: nav) else {
                MidgarLog.error("SERVER SHOT FAILED: the move offer never opened", category: .sync)
                return
            }
            if scenario == "move-done", let record = FlaccyServerLibrary.record(),
               case .offer(let offer) = ServerMoveService.shared.phase(for: record.id) {
                await ServerMoveService.shared.start(offer, choice: .stream(keepLoved: true))
                try? await Task.sleep(for: .seconds(1))
            }
        default:
            MidgarLog.error("SERVER SHOT FAILED: unknown scenario \(scenario)", category: .sync)
            return
        }
        MidgarLog.info("SERVER SHOT READY: \(scenario)", category: .sync)
    }

    private static func loveTwoSongs() {
        let remote = ((try? DatabaseManager.shared.fetchAllTracks()) ?? []).filter { $0.remoteServer != nil }.prefix(2)
        for track in remote { try? DatabaseManager.shared.setLoved(fileURL: track.fileURL, loved: true, pendingOp: nil) }
        MidgarLog.info("SERVER SHOT: loved \(remote.count) songs here", category: .sync)
    }

    private static func waitForMergeSummary(on nav: UINavigationController) async {
        for _ in 0..<150 {
            var top: UIViewController? = nav
            while let presented = top?.presentedViewController { top = presented }
            if top is ServerMergeSummaryViewController { break }
            try? await Task.sleep(for: .seconds(1))
        }
        try? await Task.sleep(for: .seconds(2))
    }

    private static func topmost(over nav: UINavigationController) -> UIViewController? {
        var top: UIViewController? = nav
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    /// Waits for the offer the way a person meets it: the merge summary of the connection first, closed with OK, then the offer.
    private static func waitForMoveOffer(on nav: UINavigationController) async -> Bool {
        for _ in 0..<240 {
            if let summary = topmost(over: nav) as? ServerMergeSummaryViewController, !summary.isBeingPresented {
                try? await Task.sleep(for: .seconds(1))
                summary.dismiss(animated: true)
            }
            if topmost(over: nav) is ServerMoveViewController {
                try? await Task.sleep(for: .seconds(1))
                return true
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    /// Closes the sheets a connection opens by itself, the merge summary and then the move offer, so another screen can open.
    private static func dismissMoveOffer(on nav: UINavigationController) async {
        var quiet = 0
        for _ in 0..<60 where quiet < 6 {
            try? await Task.sleep(for: .milliseconds(500))
            guard let top = topmost(over: nav), top is ServerMergeSummaryViewController || top is ServerMoveViewController,
                  !top.isBeingPresented
            else {
                quiet += 1
                continue
            }
            quiet = 0
            top.dismiss(animated: false)
        }
    }

    private static func fill(_ model: AddFlaccyServerViewModel, code: String?) {
        model.address = seed?.address ?? ""
        model.code = code ?? ""
    }

    private static func show(_ model: AddFlaccyServerViewModel, on nav: UINavigationController) {
        let sheet = AddFlaccyServerViewController(model: model)
        nav.present(UINavigationController(rootViewController: sheet), animated: false)
    }

    private static func open(_ scenario: String, nav: UINavigationController) async {
        let settings = SettingsViewController()
        let container = UINavigationController(rootViewController: settings)
        nav.present(container, animated: false)
        try? await Task.sleep(for: .seconds(2))
        if scenario == "detail", let record = FlaccyServerLibrary.record() {
            container.pushViewController(FlaccyServerDetailViewController(record: record), animated: false)
            try? await Task.sleep(for: .seconds(2))
        } else {
            settings.open(.servers)
        }
    }

    private static func waitForSync() async {
        for _ in 0..<60 {
            if case .upToDate = FlaccyServerStatusStore.shared.status { break }
            try? await Task.sleep(for: .seconds(1))
        }
        if let record = FlaccyServerLibrary.record() { _ = try? await RemoteCatalogSync.shared.sync(serverID: record.id) }
        try? await Task.sleep(for: .seconds(1))
    }

    /// Logs what an unattended connect did: the token stored, the sync settled, and the songs now under Servers.
    static func noteConnected(serverName: String) {
        guard drivesConnect else { return }
        Task {
            MidgarLog.info("SERVER DRIVE: connected to \(serverName)", category: .sync)
            await waitForSync()
            let record = FlaccyServerLibrary.record()
            let songs = record.flatMap { (try? DatabaseManager.shared.fetchRemoteSongCounts()[$0.id]) } ?? 0
            let hasToken = record.flatMap { URL(string: $0.baseURL) }.flatMap { ServerSyncService.deviceToken(for: $0) } != nil
            MidgarLog.info("SERVER DRIVE: device token stored \(hasToken); sync \(FlaccyServerStatusStore.shared.status.statusLine)", category: .sync)
            MidgarLog.info("SERVER DRIVE: \(songs) songs from \(serverName) are in the library under Servers (row marked \(record?.isFlaccyServer ?? false))", category: .sync)
        }
    }
}
#endif
