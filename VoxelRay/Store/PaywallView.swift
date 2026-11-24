import SwiftUI
import StoreKit

/// Landscape-optimized frosted StoreKit 2 paywall sheet showcasing Architect Pro & Prism Material Pack.
public struct PaywallView: View {
    @ObservedObject public var store: StoreManager
    @Environment(\.dismiss) private var dismiss

    public init(store: StoreManager) {
        self.store = store
    }

    public var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.06, blue: 0.13).opacity(0.76),
                    Color(red: 0.08, green: 0.12, blue: 0.22).opacity(0.82),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            HStack(spacing: 20) {
                // Left column: Hero, value proposition & trust guarantees
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: "cube.transparent.fill")
                            .font(.system(size: 25, weight: .bold))
                            .foregroundStyle(.cyan)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("VoxelRay Studio")
                                .font(.system(.title3, design: .rounded).weight(.heavy))
                                .foregroundStyle(.white)
                            Text("On-Device Ray Tracing Unlocks")
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(.white.opacity(0.78))
                        }
                    }

                    VStack(alignment: .leading, spacing: 9) {
                        featureRow(icon: "sparkles", title: "Neon Cavern & Glass Cathedral", subtitle: "Emissive neon & refractive crystal worlds", tint: .cyan)
                        featureRow(icon: "camera.aperture", title: "Watermark-Free 4K Photo Mode", subtitle: "Clean 64-sample renders ready to share", tint: .yellow)
                        featureRow(icon: "diamond.fill", title: "Prism Crystal Brush", subtitle: "Sculpt iridescent dispersive glass towers", tint: .mint)
                    }
                    .padding(13)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 15, style: .continuous))

                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                        Text("One-Time Purchase · No Subscription · Family Sharing")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.86))
                    }

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
                        .padding(.vertical, 7)
                        .background(.white.opacity(0.10), in: Capsule())
                    }
                    .accessibilityIdentifier("paywall.restore")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Right column: Purchase cards + close
                VStack(spacing: 11) {
                    HStack {
                        Spacer()
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(.white.opacity(0.82))
                        }
                        .accessibilityIdentifier("paywall.close")
                    }

                    productCard(
                        title: "Architect Pro",
                        badge: "BEST VALUE",
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
                        badge: nil,
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
            .padding(20)
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
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.white.opacity(0.76))
            }
        }
    }

    private func productCard(
        title: String,
        badge: String?,
        description: String,
        priceText: String,
        unlocked: Bool,
        accent: Color,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                if let badge, !unlocked {
                    Text(badge)
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            LinearGradient(colors: [.yellow, .orange], startPoint: .leading, endPoint: .trailing),
                            in: Capsule()
                        )
                }
                Spacer()
                Text(unlocked ? "Owned" : priceText)
                    .font(.system(.subheadline, design: .rounded).weight(.heavy))
                    .foregroundStyle(unlocked ? .green : accent)
            }

            Text(description)
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)

            Button(action: action) {
                HStack {
                    Spacer()
                    Text(unlocked ? "Unlocked" : "Unlock · \(priceText)")
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .foregroundStyle(.black)
                    Spacer()
                }
                .padding(.vertical, 8)
                .background(unlocked ? Color.green.opacity(0.88) : accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .disabled(unlocked || store.isLoading)
            .accessibilityIdentifier(identifier)
        }
        .padding(13)
        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(accent.opacity(0.55), lineWidth: 1)
        )
    }
}
