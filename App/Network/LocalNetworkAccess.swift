import Foundation
import Network

/// Asks the system for local network access before Flaccy first reaches a server on this Wi-Fi. The first connection to the
/// local network shows the permission alert and fails while it is up, so the alert is raised ahead of time, while the person
/// is still reading the setup steps, by briefly browsing for Flaccy's Bonjour type (declared in NSBonjourServices).
@MainActor
enum LocalNetworkAccess {

    private static let serviceType = "_flaccy._tcp"
    private static let browseFor: Duration = .seconds(20)
    private static var browser: NWBrowser?

    static func requestIfNeeded() {
        guard browser == nil else { return }
        let started = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: NWParameters())
        started.stateUpdateHandler = { _ in }
        started.start(queue: .main)
        browser = started
        Task { @MainActor in
            try? await Task.sleep(for: browseFor)
            browser?.cancel()
            browser = nil
        }
    }
}
