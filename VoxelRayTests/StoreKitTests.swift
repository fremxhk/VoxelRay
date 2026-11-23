import XCTest
import StoreKit
import StoreKitTest
@testable import VoxelRay

@MainActor
final class StoreKitTests: XCTestCase {
    private var session: SKTestSession!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        session = try SKTestSession(configurationFileNamed: "VoxelRay")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
    }

    override func tearDown() async throws {
        session?.clearTransactions()
        session = nil
        try await super.tearDown()
    }

    func testInitialLockedStatePurchasePersistenceAndRestore() async throws {
        let store = StoreManager(autoStart: false)
        await store.loadProducts()
        await store.refreshEntitlements()

        XCTAssertEqual(store.products.count, 2, "statusMessage: \(store.statusMessage ?? "none")")
        XCTAssertNotNil(store.proProduct)
        XCTAssertNotNil(store.crystalProduct)
        XCTAssertFalse(store.isProUnlocked)
        XCTAssertFalse(store.isCrystalPackUnlocked)

        // Purchase Architect Pro
        let proBought = await store.purchase(productID: StoreConfig.proProductID)
        XCTAssertTrue(proBought)
        XCTAssertTrue(store.isProUnlocked)
        XCTAssertFalse(store.isCrystalPackUnlocked)

        // Purchase Prism Material Pack
        let crystalBought = await store.purchase(productID: StoreConfig.crystalPackProductID)
        XCTAssertTrue(crystalBought)
        XCTAssertTrue(store.isProUnlocked)
        XCTAssertTrue(store.isCrystalPackUnlocked)

        // Verify entitlement persistence across fresh StoreManager instance
        let freshStore = StoreManager(autoStart: false)
        await freshStore.refreshEntitlements()
        XCTAssertTrue(freshStore.isProUnlocked)
        XCTAssertTrue(freshStore.isCrystalPackUnlocked)

        // Verify restore flow preserves active entitlements
        await freshStore.restorePurchases()
        XCTAssertTrue(freshStore.isProUnlocked)
        XCTAssertTrue(freshStore.isCrystalPackUnlocked)
    }
}
