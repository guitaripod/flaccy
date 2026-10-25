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

/// What Flaccy sells: one Universal Purchase app (D17), so the iOS products on every platform, all granting `pro`. The
/// three product ids of the old separate Mac app are never sold again but still map to `pro`, so a Mac purchase the
/// ledger already knows keeps unlocking Pro. The `LEGACY_MAC_HANDOFF` build of that old app keeps selling its own ids.
nonisolated enum FlaccyProducts {
    static let universalYearly = "com.midgarcorp.flaccy.pro.yearly"
    static let universalLifetime = "com.midgarcorp.flaccy.lifetime"
    static let universalWelcomeLifetime = "com.midgarcorp.flaccy.lifetime.welcome"

    static let legacyMacYearly = "com.midgarcorp.flaccy.mac.pro.yearly"
    static let legacyMacLifetime = "com.midgarcorp.flaccy.mac.lifetime"
    static let legacyMacWelcomeLifetime = "com.midgarcorp.flaccy.mac.lifetime.welcome"

    #if LEGACY_MAC_HANDOFF
    static let yearly = legacyMacYearly
    static let lifetime = legacyMacLifetime
    static let welcomeLifetime = legacyMacWelcomeLifetime
    #else
    static let yearly = universalYearly
    static let lifetime = universalLifetime
    static let welcomeLifetime = universalWelcomeLifetime
    #endif

    static let entitlement = "pro"

    static let all = [yearly, lifetime, welcomeLifetime]

    static let grantingProductIDs = [
        universalYearly, universalLifetime, universalWelcomeLifetime,
        legacyMacYearly, legacyMacLifetime, legacyMacWelcomeLifetime,
    ]

    /// The registry's `[commerce]` for this platform: MidgarStore buys and finishes.
    static func configuration(directory: URL? = nil) -> MidgarStoreConfiguration {
        MidgarStoreConfiguration(
            appID: FlaccyMidgar.appID,
            productIDs: all,
            entitlementsByProduct: Dictionary(uniqueKeysWithValues: grantingProductIDs.map { ($0, entitlement) }),
            mode: .purchases,
            directory: directory
        )
    }
}
