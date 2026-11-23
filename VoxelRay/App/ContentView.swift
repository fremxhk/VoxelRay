import SwiftUI

struct ContentView: View {
    @StateObject private var renderer = Renderer() ?? {
        fatalError("Metal device unavailable")
    }()
    @StateObject private var store = StoreManager()
    @State private var showPaywall = false

    var body: some View {
        ZStack {
            MetalView(renderer: renderer) { normPt in
                _ = renderer.handleViewportTap(at: normPt, isPrismUnlocked: store.isCrystalPackUnlocked)
            }
            .ignoresSafeArea()

            HUDView(
                renderer: renderer,
                isProUnlocked: store.isProUnlocked,
                isCrystalUnlocked: store.isCrystalPackUnlocked,
                onSelectBiome: { biome in
                    if biome.requiresPro && !store.isProUnlocked {
                        showPaywall = true
                    } else {
                        renderer.selectBiome(biome)
                    }
                },
                onSelectCrystalBrush: {
                    if !store.isCrystalPackUnlocked {
                        showPaywall = true
                    } else {
                        renderer.brushMode = .prismCrystal
                    }
                },
                onOpenPaywall: {
                    showPaywall = true
                }
            )
        }
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showPaywall) {
            PaywallView(store: store)
        }
        .sheet(isPresented: $renderer.showShareSheet) {
            if let img = renderer.capturedPhotoImage {
                PhotoShareSheet(image: img) {
                    renderer.exitPhotoMode()
                }
            }
        }
    }
}
