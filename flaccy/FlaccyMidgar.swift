import Foundation
import MidgarCore
import MidgarPortal

/// The composition root of everything Flaccy shares with the other Midgar apps: the Midgar ID, the gateway client built
/// on it for "Your Midgar", the client of Flaccy's own server and the portal configuration. The iOS and Mac apps both
/// build it, so one instance lives for the whole process and there is one identity.
nonisolated final class FlaccyMidgar: Sendable {
    /// The registry slug: the `X-App-ID` of every gateway call.
    static let appID = "flaccy"

    /// The bundle id the identity service checks against the registry when it mints or attaches an ID.
    static let fallbackBundleID = "com.midgarcorp.flaccy"

    static let shared = FlaccyMidgar()

    /// The Midgar ID client. Minted on first launch, attached on every later one, shared through the keychain group.
    let identity: MidgarIdentity

    /// The gateway client that carries the Midgar ID's bearer token, for the portal's "Your Midgar".
    let account: MidgarHTTPClient

    /// The client of flaccy-api behind the gateway: the AI metadata proxy, Last.fm signing and the sample album.
    let api: FlaccyAPIClient

    private init() {
        let configuration = MidgarHTTPConfiguration(appID: Self.appID)
        let identity = MidgarIdentity(
            httpConfiguration: configuration, bundleID: Bundle.main.bundleIdentifier ?? Self.fallbackBundleID)
        self.identity = identity
        account = MidgarHTTPClient(configuration: identity.authorizing(configuration))
        api = FlaccyAPIClient()
    }

    /// The portal configuration of Settings: the authorized client, so "Your Midgar" shows what the person owns in the
    /// other apps and a cross-sell skips an app they already use.
    @MainActor
    var portalConfig: MidgarPortal.MidgarConfig {
        MidgarPortal.MidgarConfig(placement: "settings", account: Self.reachesMidgarServices ? account : nil)
    }

    /// Opens the log file. Call first thing at launch so nothing before the rest of the setup is lost.
    static func configureLogging() {
        FlaccyLogging.configure()
    }

    /// Hands the Last.fm service its API key, configures anonymous signals for the portal and starts the Midgar ID in
    /// the background. Call once at launch. A test host or a screenshot seed talks to no Midgar service.
    @MainActor
    func start() {
        LastFMService.configure(apiKey: Secrets.lastFMApiKey)
        guard Self.reachesMidgarServices else {
            MidgarLog.info("Midgar services not started: test host or screenshot seed", category: .auth)
            return
        }
        MidgarSignals.configure(configuration: MidgarHTTPConfiguration(appID: Self.appID))
        let identity = identity
        Task {
            do {
                _ = try await identity.midgarId
                MidgarLog.info("Midgar ID ready", category: .auth)
            } catch {
                MidgarLog.info("Midgar ID not available yet: \(error)", category: .auth)
            }
        }
    }

    /// False inside an XCTest or Swift Testing host and in a screenshot seed run, which must not mint identities or send
    /// anything to the production services.
    static var reachesMidgarServices: Bool {
        let info = ProcessInfo.processInfo
        if info.environment["XCTestConfigurationFilePath"] != nil { return false }
        return !info.arguments.contains("--seed-screenshots")
    }
}
