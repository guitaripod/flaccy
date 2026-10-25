import MidgarCommerce
import Testing

@testable import flaccy

@MainActor
struct FlaccyProductsTests {

    nonisolated private static let universalProductIDs = [
        "com.midgarcorp.flaccy.pro.yearly",
        "com.midgarcorp.flaccy.lifetime",
        "com.midgarcorp.flaccy.lifetime.welcome",
    ]

    nonisolated private static let oldMacProductIDs = [
        "com.midgarcorp.flaccy.mac.pro.yearly",
        "com.midgarcorp.flaccy.mac.lifetime",
        "com.midgarcorp.flaccy.mac.lifetime.welcome",
    ]

    @Test(arguments: universalProductIDs + oldMacProductIDs)
    func everyUniversalAndOldMacProductGrantsPro(_ productID: String) {
        let entitlements = FlaccyProducts.configuration().entitlementsByProduct

        #expect(entitlements[productID] == "pro")
    }

    @Test func theUniversalBuildSellsOnlyTheThreeUniversalProducts() {
        let configuration = FlaccyProducts.configuration()

        #expect(configuration.productIDs == Self.universalProductIDs)
        #expect(Set(configuration.productIDs).isDisjoint(with: Self.oldMacProductIDs))
    }

    @Test func nothingElseGrantsPro() {
        let entitlements = FlaccyProducts.configuration().entitlementsByProduct

        #expect(Set(entitlements.keys) == Set(Self.universalProductIDs + Self.oldMacProductIDs))
        #expect(Set(entitlements.values) == ["pro"])
    }
}
