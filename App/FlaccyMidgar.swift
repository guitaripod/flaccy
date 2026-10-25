import Foundation
import MidgarCommerce
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

    /// The purchase engine (D2): StoreKit 2 with the ledger as the record. Nil in a test
    /// host or a screenshot seed, which must not reach the ledger.
    let store: MidgarStore?

    private init() {
        let configuration = MidgarHTTPConfiguration(appID: Self.appID)
        let identity = MidgarIdentity(
            httpConfiguration: configuration, bundleID: Bundle.main.bundleIdentifier ?? Self.fallbackBundleID)
        self.identity = identity
        let account = MidgarHTTPClient(configuration: identity.authorizing(configuration))
        self.account = account
        api = FlaccyAPIClient()
        store = Self.reachesMidgarServices
            ? MidgarStore(configuration: FlaccyProducts.configuration(), identity: identity, http: account)
            : nil
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

/// What Flaccy sells on this platform. iOS and Mac are separate purchases with their own products, never a universal
/// purchase; each platform has the yearly subscription, the lifetime unlock and the welcome-back lifetime, all granting
/// `pro`.
nonisolated enum FlaccyProducts {
    #if os(macOS)
    static let yearly = "com.midgarcorp.flaccy.mac.pro.yearly"
    static let lifetime = "com.midgarcorp.flaccy.mac.lifetime"
    static let welcomeLifetime = "com.midgarcorp.flaccy.mac.lifetime.welcome"
    #else
    static let yearly = "com.midgarcorp.flaccy.pro.yearly"
    static let lifetime = "com.midgarcorp.flaccy.lifetime"
    static let welcomeLifetime = "com.midgarcorp.flaccy.lifetime.welcome"
    #endif

    static let entitlement = "pro"

    static let all = [yearly, lifetime, welcomeLifetime]

    /// The registry's `[commerce]` for this platform: MidgarStore buys and finishes.
    static func configuration(directory: URL? = nil) -> MidgarStoreConfiguration {
        MidgarStoreConfiguration(
            appID: FlaccyMidgar.appID,
            productIDs: all,
            entitlementsByProduct: Dictionary(uniqueKeysWithValues: all.map { ($0, entitlement) }),
            mode: .purchases,
            directory: directory
        )
    }
}
