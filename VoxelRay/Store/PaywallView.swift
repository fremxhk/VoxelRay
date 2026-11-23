import SwiftUI
import StoreKit

/// Landscape-optimized StoreKit 2 paywall sheet for Architect Pro & Prism Material Pack.
public struct PaywallView: View {
    @ObservedObject public var store: StoreManager
    @Environment(\.dismiss) private var dismiss

    public init(store: StoreManager) {
        self.store = store
    }

    public var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.07, blue: 0.14), Color(red: 0.09, green: 0.13, blue: 0.24)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            HStack(spacing: 22) {
                // Left column: Hero & Free vs Pro comparison
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Image(systemName: "cube.transparent.fill")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(.cyan)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("VoxelRay Studio")
                                .font(.system(.title3, design: .rounded).weight(.heavy))
                                .foregroundStyle(.white)
                            Text("On-Device Ray Tracing Unlocks")
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(.white.opacity(0.72))
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        featureRow(icon: "sparkles", title: "Neon Cavern & Glass Cathedral", subtitle: "Full path-traced emissive & refractive biomes", tint: .cyan)
                        featureRow(icon: "camera.aperture", title: "Watermark-Free 4K Photo Mode", subtitle: "Clean 64-sample renders ready to share", tint: .yellow)
                        featureRow(icon: "diamond.fill", title: "Prism Crystal Brush", subtitle: "Sculpt iridescent dispersive glass voxels", tint: .mint)
                    }
                    .padding(14)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    Spacer()

                    Button {
                        Task { await store.restorePurchases() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise.circle.fill")
                            Text("Restore Purchases")
                                .fontWeight(.semibold)
                        }
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.cyan)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.08), in: Capsule())
                    }
                    .accessibilityIdentifier("paywall.restore")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Right column: Purchase cards + close
                VStack(spacing: 12) {
                    HStack {
                        Spacer()
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                        .accessibilityIdentifier("paywall.close")
                    }

                    productCard(
                        title: "Architect Pro",
                        description: "Neon Cavern & Glass Cathedral biomes + clean 4K Photo Mode exports.",
                        priceText: store.proProduct?.displayPrice ?? "$4.99",
                        unlocked: store.purchasedProductIDs.contains(StoreConfig.proProductID),
                        accent: .cyan,
                        identifier: "paywall.purchase.pro"
                    ) {
                        Task { _ = await store.purchase(productID: StoreConfig.proProductID) }
                    }

                    productCard(
                        title: "Prism Material Pack",
                        description: "Refractive Prism Crystal brush for sculpting glowing glass towers.",
                        priceText: store.crystalProduct?.displayPrice ?? "$1.99",
                        unlocked: store.purchasedProductIDs.contains(StoreConfig.crystalPackProductID),
                        accent: .mint,
                        identifier: "paywall.purchase.crystal"
                    ) {
                        Task { _ = await store.purchase(productID: StoreConfig.crystalPackProductID) }
                    }

                    if let msg = store.statusMessage {
                        Text(msg)
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(.yellow)
                            .lineLimit(2)
                    }

                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
            .padding(22)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("paywall.root")
        .task {
            if store.products.isEmpty {
                await store.loadProducts()
            }
        }
    }

    private func featureRow(icon: String, title: String, subtitle: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
    }

    private func productCard(
        title: String,
        description: String,
        priceText: String,
        unlocked: Bool,
        accent: Color,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                Text(unlocked ? "Owned" : priceText)
                    .font(.system(.subheadline, design: .rounded).weight(.heavy))
                    .foregroundStyle(unlocked ? .green : accent)
            }

            Text(description)
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)

            Button(action: action) {
                HStack {
                    Spacer()
                    Text(unlocked ? "Unlocked" : "Unlock · \(priceText)")
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .foregroundStyle(.black)
                    Spacer()
                }
                .padding(.vertical, 9)
                .background(unlocked ? Color.green.opacity(0.85) : accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .disabled(unlocked || store.isLoading)
            .accessibilityIdentifier(identifier)
        }
        .padding(14)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(accent.opacity(0.45), lineWidth: 1)
        )
    }
}
