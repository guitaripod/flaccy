import Foundation
import MidgarCommerce
import MidgarCore
import StoreKit
import StoreKitTest
import Testing
import UIKit

@testable import flaccy

/// Buys every plan through `PurchaseManager` on a `MidgarStore` with Flaccy's own configuration against
/// `Flaccy.storekit`, the file the scheme runs with, so the products, the welcome-back lifetime and the mapping from
/// the `pro` entitlement to a plan are checked together on a real StoreKit. StoreKit is process-wide, so the suite
/// runs serially. A test session signs its transactions with Xcode's local certificate, so the store never reports
/// them to the ledger; the ledger here is a stub that knows the Midgar ID, holds nothing and counts what arrives.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct PurchaseStoreKitTests {
    private struct Harness {
        let store: MidgarStore
        let manager: PurchaseManager
        let session: SKTestSession
    }

    private static let configurationURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("flaccyUITests/Flaccy.storekit")

    private func makeHarness() throws -> Harness {
        let session = try SKTestSession(contentsOf: Self.configurationURL)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        session.askToBuyEnabled = false
        LedgerStub.reset()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flaccy-purchase-" + UUID().uuidString, isDirectory: true)
        let store = MidgarStore(
            configuration: FlaccyProducts.configuration(directory: directory),
            identity: StubIdentity(),
            http: LedgerStub.client()
        )
        return Harness(store: store, manager: PurchaseManager(store: store), session: session)
    }

    @Test func theConfigurationFileSellsExactlyTheThreeProducts() throws {
        let file = try JSONDecoder().decode(StoreKitFile.self, from: Data(contentsOf: Self.configurationURL))
        let sold = file.products.map(\.productID) + file.subscriptionGroups.flatMap(\.subscriptions).map(\.productID)

        #expect(Set(sold) == Set(FlaccyProducts.all))
    }

    @Test func theOffersAreTheYearlyAndLifetimePlansWithTheWelcomeBackProductKept() async throws {
        let harness = try makeHarness()

        let offers = await harness.manager.loadOffersIfNeeded()

        #expect(offers.map(\.plan) == [.yearly, .lifetime])
        #expect(offers.map(\.storeProduct.id) == [FlaccyProducts.yearly, FlaccyProducts.lifetime])
        #expect(offers.allSatisfy { !$0.isWelcomeBack })
        #expect(harness.manager.lapsedOfferExists)
        let welcome = try #require(harness.manager.lapsedLifetimeOffer)
        #expect(welcome.storeProduct.id == FlaccyProducts.welcomeLifetime)
        #expect(welcome.isWelcomeBack)
        #expect(welcome.regularPrice == harness.manager.lifetimeOffer?.displayPrice)
        await harness.store.stop()
    }

    @Test(arguments: [PurchasePlan.yearly, .lifetime])
    func eachPlanUnlocksAsItselfAndCarriesTheMidgarID(_ plan: PurchasePlan) async throws {
        let harness = try makeHarness()
        await harness.manager.refresh()
        #expect(!harness.manager.state.isPurchased)
        #expect(harness.manager.hasLoadedEntitlements)

        let outcome = try await buy(plan, with: harness.manager)

        #expect(outcome == .purchased)
        #expect(harness.manager.state == .purchased(plan))
        let productID = plan == .yearly ? FlaccyProducts.yearly : FlaccyProducts.lifetime
        guard case .verified(let transaction)? = await Transaction.latest(for: productID) else {
            Issue.record("no verified transaction for \(productID)")
            return
        }
        #expect(transaction.appAccountToken == UUID(uuidString: StubIdentity.midgarID))
        #expect(LedgerStub.reportCount == 0)
        await harness.store.stop()
    }

    @Test func lifetimeWinsOverARunningYearlySubscription() async throws {
        let harness = try makeHarness()
        _ = try await buy(.yearly, with: harness.manager)
        _ = try await buy(.lifetime, with: harness.manager)

        #expect(harness.manager.state == .purchased(.lifetime))
        await harness.store.stop()
    }

    @Test func aPurchaseMadeBeforeTheStoreIsFoundAtLaunchAndByRestore() async throws {
        let harness = try makeHarness()
        try harness.session.buyProduct(productIdentifier: FlaccyProducts.lifetime)
        let relaunched = PurchaseManager(store: harness.store)

        await relaunched.refresh()
        #expect(relaunched.state == .purchased(.lifetime))
        #expect(await relaunched.restore() == .restored)
        await harness.store.stop()
    }

    @Test func aRefundedLifetimeTakesPlaybackAway() async throws {
        let harness = try makeHarness()
        _ = try await buy(.lifetime, with: harness.manager)
        let transaction = try #require(harness.session.allTransactions().first)

        try harness.session.refundTransaction(identifier: UInt(transaction.identifier))

        #expect(await eventually {
            await harness.manager.refresh()
            return !harness.manager.state.isPurchased
        })
        await harness.store.stop()
    }

    @Test func aRestoreWithNothingBoughtSaysSo() async throws {
        let harness = try makeHarness()

        #expect(await harness.manager.restore() == .nothingToRestore)
        await harness.store.stop()
    }

    @Test func storeFailuresBecomeSentencesAndACancelIsNotOne() {
        #expect(PurchaseFailure(.storeKit("StoreKitError.networkError(NSURLErrorDomain -1009)")) == .unreachable)
        #expect(PurchaseFailure(.storeKit("StoreKitError.notAvailableInStorefront")) == .notAvailableInStorefront)
        #expect(PurchaseFailure(.unknownProduct(FlaccyProducts.lifetime)) == .notAvailableInStorefront)
        #expect(PurchaseFailure(.unverifiedTransaction(productID: FlaccyProducts.lifetime)) == .unverified)
        #expect(PurchaseFailure(.storeKit("StoreKitError.systemError")) == .other)
        #expect(PurchaseFailure.isCancellation(.storeKit("StoreKitError.userCancelled")))
        #expect(!PurchaseFailure.isCancellation(.unverifiedTransaction(productID: FlaccyProducts.lifetime)))
        #expect([PurchaseFailure.unreachable, .notAvailableInStorefront, .unverified, .other].allSatisfy {
            !($0.errorDescription ?? "").isEmpty
        })
    }

    /// Buys `plan` with the confirmation anchored to the host app's window scene, as the paywall does. A scene-less
    /// purchase in the test host never completes, because StoreKit finds no window to confirm in.
    private func buy(_ plan: PurchasePlan, with manager: PurchaseManager) async throws -> PurchaseManager.PurchaseOutcome {
        let offers = await manager.loadOffersIfNeeded()
        let offer = try #require(offers.first { $0.plan == plan })
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        return try await manager.purchase(offer, confirmIn: scene)
    }

    /// Polls `condition` until it holds or `timeout` passes, for the StoreKit changes that reach the store a moment
    /// after the session makes them.
    private func eventually(timeout: Duration = .seconds(10), _ condition: () async -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await condition()
    }
}

/// The parts of a StoreKit configuration file the product check reads.
private nonisolated struct StoreKitFile: Decodable {
    struct Item: Decodable {
        let productID: String
    }

    struct Group: Decodable {
        let subscriptions: [Item]
    }

    let products: [Item]
    let subscriptionGroups: [Group]
}

/// A Midgar ID that is always there, in the UUID form `appAccountToken` takes.
private nonisolated struct StubIdentity: MidgarStoreIdentity {
    static let midgarID = "3B7E2A10-5C4D-4E6F-9A81-2D3C4B5A6F70"

    var midgarId: String {
        get async throws { Self.midgarID }
    }
}

/// The ledger the store talks to in these tests: it answers the entitlements query with nothing for the stub Midgar
/// ID and counts transaction reports. The lock guards the counter, which is what makes the unchecked conformance sound.
private nonisolated final class LedgerStub: URLProtocol, @unchecked Sendable {
    private static let host = "ledger.flaccy-tests.invalid"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var reports = 0

    static var reportCount: Int { lock.withLock { reports } }

    static func reset() {
        lock.withLock { reports = 0 }
    }

    static func client() -> MidgarHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LedgerStub.self]
        return MidgarHTTPClient(configuration: MidgarHTTPConfiguration(
            baseURL: URL(string: "https://\(host)")!,
            appID: FlaccyMidgar.appID,
            session: URLSession(configuration: configuration),
            timeout: 5
        ))
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (status, body) = Self.answer(method: request.httpMethod ?? "GET", path: url.path)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func answer(method: String, path: String) -> (Int, String) {
        switch (method, path) {
        case ("POST", "/v1/ledger/transactions"):
            lock.withLock { reports += 1 }
            return (200, #"{"ok":true}"#)
        case ("GET", "/v1/ledger/entitlements"):
            let now = Int(Date().timeIntervalSince1970 * 1000)
            return (200, #"{"midgarId":"\#(StubIdentity.midgarID)","environment":"Sandbox","serverTime":\#(now),"entitlements":[]}"#)
        default:
            return (404, "{}")
        }
    }
}
