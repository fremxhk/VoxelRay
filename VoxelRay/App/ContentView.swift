import SwiftUI

struct ContentView: View {
    @StateObject private var renderer = Renderer() ?? {
        fatalError("Metal device unavailable")
    }()

    var body: some View {
        ZStack {
            MetalView(renderer: renderer)
                .ignoresSafeArea()

            HUDView(renderer: renderer)
        }
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
    }
}
