import SwiftUI

struct ContentView: View {
    @StateObject private var renderer = Renderer() ?? {
        fatalError("Metal device unavailable")
    }()

    var body: some View {
        ZStack {
            MetalView(renderer: renderer) { normPt in
                _ = renderer.handleViewportTap(at: normPt, isPrismUnlocked: false)
            }
            .ignoresSafeArea()

            HUDView(
                renderer: renderer,
                isProUnlocked: false,
                isCrystalUnlocked: false,
                onSelectBiome: { biome in
                    if !biome.requiresPro {
                        renderer.selectBiome(biome)
                    }
                },
                onSelectCrystalBrush: {
                    renderer.brushMode = .carve
                },
                onOpenPaywall: {}
            )
        }
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $renderer.showShareSheet) {
            if let img = renderer.capturedPhotoImage {
                PhotoShareSheet(image: img) {
                    renderer.exitPhotoMode()
                }
            }
        }
    }
}
