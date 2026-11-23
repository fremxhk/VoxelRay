import Foundation
import StoreKit
import Combine

/// Zero-backend StoreKit 2 manager verifying non-consumable entitlements on-device.
@MainActor
public final class StoreManager: ObservableObject {
    @Published public private(set) var products: [Product] = []
    @Published public private(set) var purchasedProductIDs: Set<String> = []
    @Published public private(set) var isLoading: Bool = false
    @Published public var statusMessage: String?

    private var updatesTask: Task<Void, Never>?
    private let showcaseProOverride: Bool

    public init(autoStart: Bool = true) {
        self.showcaseProOverride = ProcessInfo.processInfo.arguments.contains("--uitesting-screenshots")
        if autoStart {
            updatesTask = listenForTransactionUpdates()
            Task {
                await loadProducts()
                await refreshEntitlements()
            }
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    public var isProUnlocked: Bool {
        showcaseProOverride || purchasedProductIDs.contains(StoreConfig.proProductID)
    }

    public var isCrystalPackUnlocked: Bool {
        showcaseProOverride || purchasedProductIDs.contains(StoreConfig.crystalPackProductID)
    }

    public var proProduct: Product? {
        products.first { $0.id == StoreConfig.proProductID }
    }

    public var crystalProduct: Product? {
        products.first { $0.id == StoreConfig.crystalPackProductID }
    }

    public func loadProducts() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await Product.products(for: StoreConfig.allProductIDs)
            products = fetched.sorted { $0.price > $1.price }
        } catch {
            statusMessage = "Unable to load StoreKit products: \(error.localizedDescription)"
        }
    }

    public func refreshEntitlements() async {
        var active = Set<String>()
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.revocationDate == nil {
                active.insert(transaction.productID)
            }
        }
        purchasedProductIDs = active
    }

    @discardableResult
    public func purchase(productID: String) async -> Bool {
        if products.isEmpty {
            await loadProducts()
        }
        guard let product = products.first(where: { $0.id == productID }) else {
            statusMessage = "Product unavailable. Check App Store connection."
            return false
        }
        return await purchase(product)
    }

    @discardableResult
    public func purchase(_ product: Product) async -> Bool {
        isLoading = true
        statusMessage = nil
        defer { isLoading = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    statusMessage = "Transaction verification failed."
                    return false
                }
                await transaction.finish()
                await refreshEntitlements()
                statusMessage = "\(product.displayName) unlocked."
                return true
            case .userCancelled:
                statusMessage = nil
                return false
            case .pending:
                statusMessage = "Purchase pending approval."
                return false
            @unknown default:
                return false
            }
        } catch {
            statusMessage = "Purchase failed: \(error.localizedDescription)"
            return false
        }
    }

    public func restorePurchases() async {
        isLoading = true
        statusMessage = nil
        defer { isLoading = false }

        do {
            try await AppStore.sync()
            await refreshEntitlements()
            statusMessage = purchasedProductIDs.isEmpty ? "No previous purchases found." : "Purchases restored."
        } catch {
            statusMessage = "Restore failed: \(error.localizedDescription)"
        }
    }

    private func listenForTransactionUpdates() -> Task<Void, Never> {
        Task.detached(priority: .background) { [weak self] in
            for await update in Transaction.updates {
                guard case .verified(let transaction) = update else { continue }
                await transaction.finish()
                await self?.refreshEntitlements()
            }
        }
    }
}
