import Foundation
import MidgarCore

/// Whether Flaccy's model features work where this device connects from, as Midgar's servers answer it. Screens that
/// offer a model feature observe `didChangeNotification` on the main queue, so the answer reaches them whichever
/// thread learned it.
nonisolated enum FlaccyModelRegion {
    static let didChangeNotification = Notification.Name("FlaccyModelRegionDidChange")

    nonisolated(unsafe) private static let relay: any NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: MidgarModelRegion.didChangeNotification, object: nil, queue: .main
    ) { _ in
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static var modelsAvailable: Bool {
        MidgarModelRegion.shared.modelsAvailable
    }

    /// Starts relaying Midgar's changes to the main queue. Call once at launch.
    static func startRelay() {
        _ = relay
    }

    /// Asks Midgar's gateway whether model features work here, through the app's own authorized client.
    static func refresh() async {
        await MidgarModelRegion.shared.refresh(client: FlaccyMidgar.shared.account)
    }
}
