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
                        if renderer.previewBiome == biome {
                            showPaywall = true
                        } else {
                            renderer.selectBiome(biome, isPreview: true)
                        }
                    } else {
                        renderer.selectBiome(biome, isPreview: false)
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
        .onAppear {
            renderer.onPreviewUpgradeRequested = {
                showPaywall = true
            }
        }
        .onChange(of: store.isProUnlocked) { _, unlocked in
            if unlocked {
                renderer.clearPreviewBanner()
                renderer.sound.playUnlockFanfare()
            }
        }
        .onChange(of: store.isCrystalPackUnlocked) { _, unlocked in
            if unlocked {
                renderer.sound.playUnlockFanfare()
            }
        }
        .sheet(isPresented: $showPaywall, onDismiss: {
            if !store.isProUnlocked && renderer.activeBiome.requiresPro {
                renderer.clearPreviewBanner()
                renderer.selectBiome(.sunlitCourtyard)
            }
        }) {
            PaywallView(store: store)
                .presentationBackground(.ultraThinMaterial)
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
