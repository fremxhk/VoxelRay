import SwiftUI

/// Compact landscape HUD overlay for voxel sculpting, biome selection, ray controls, and Photo Mode.
public struct HUDView: View {
    @ObservedObject public var renderer: Renderer
    public var isProUnlocked: Bool
    public var isCrystalUnlocked: Bool
    public var onSelectBiome: (VoxelBiome) -> Void
    public var onSelectCrystalBrush: () -> Void
    public var onOpenPaywall: () -> Void

    @State private var joystickOffset: CGSize = .zero
    private let joystickRadius: CGFloat = 42

    public init(
        renderer: Renderer,
        isProUnlocked: Bool = false,
        isCrystalUnlocked: Bool = false,
        onSelectBiome: @escaping (VoxelBiome) -> Void = { _ in },
        onSelectCrystalBrush: @escaping () -> Void = {},
        onOpenPaywall: @escaping () -> Void = {}
    ) {
        self.renderer = renderer
        self.isProUnlocked = isProUnlocked
        self.isCrystalUnlocked = isCrystalUnlocked
        self.onSelectBiome = onSelectBiome
        self.onSelectCrystalBrush = onSelectCrystalBrush
        self.onOpenPaywall = onOpenPaywall
    }

    public var body: some View {
        ZStack {
            if renderer.isPhotoModeActive {
                photoModeOverlay
            } else {
                sandboxControlsOverlay
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hud.root")
    }

    private var sandboxControlsOverlay: some View {
        VStack(spacing: 0) {
            // Top bar: title, telemetry, biomes, Photo Mode
            HStack(spacing: 8) {
                Label("VoxelRay", systemImage: "cube.transparent.fill")
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())

                Text(String(format: "%.0f FPS", renderer.fps))
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.cyan)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.58), in: Capsule())
                    .accessibilityIdentifier("hud.fps")

                Text(renderer.thermalBadgeText)
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.58), in: Capsule())
                    .accessibilityIdentifier("hud.metalfx.badge")

                Spacer()

                // Biome switcher pills
                HStack(spacing: 6) {
                    ForEach(VoxelBiome.allCases) { biome in
                        let locked = biome.requiresPro && !isProUnlocked
                        let selected = renderer.activeBiome == biome
                        Button {
                            onSelectBiome(biome)
                        } label: {
                            HStack(spacing: 4) {
                                if locked {
                                    Image(systemName: "lock.fill")
                                        .font(.system(size: 10, weight: .bold))
                                }
                                Text(biome.shortTitle)
                                    .font(.system(.caption, design: .rounded).weight(.semibold))
                            }
                            .foregroundStyle(selected ? .black : .white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                selected ? AnyShapeStyle(Color.cyan) : AnyShapeStyle(.black.opacity(0.55)),
                                in: Capsule()
                            )
                        }
                        .accessibilityIdentifier(biomeIdentifier(for: biome))
                    }
                }

                if !isProUnlocked {
                    Button {
                        onOpenPaywall()
                    } label: {
                        Label("Pro", systemImage: "sparkles")
                            .font(.system(.caption, design: .rounded).weight(.bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                LinearGradient(colors: [.yellow, .orange], startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: Capsule()
                            )
                    }
                    .accessibilityIdentifier("hud.button.pro")
                }

                Button {
                    renderer.enterPhotoMode(isProUnlocked: isProUnlocked)
                } label: {
                    Label("Photo Mode", systemImage: "camera.aperture")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(.indigo.opacity(0.85), in: Capsule())
                }
                .accessibilityIdentifier("hud.button.photoMode")
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            Spacer()

            // Bottom bar: Left joystick + brush selector, Right sliders + Reset World
            HStack(alignment: .bottom, spacing: 14) {
                HStack(alignment: .bottom, spacing: 12) {
                    virtualJoystick

                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            renderer.brushMode = .carve
                        } label: {
                            Label("Carve", systemImage: "burst.fill")
                                .font(.system(.caption, design: .rounded).weight(.semibold))
                                .foregroundStyle(renderer.brushMode == .carve ? .black : .white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    renderer.brushMode == .carve ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.black.opacity(0.6)),
                                    in: Capsule()
                                )
                        }
                        .accessibilityIdentifier("hud.brush.carve")

                        Button {
                            onSelectCrystalBrush()
                        } label: {
                            HStack(spacing: 4) {
                                if !isCrystalUnlocked {
                                    Image(systemName: "lock.fill")
                                        .font(.system(size: 10, weight: .bold))
                                }
                                Label("Prism", systemImage: "diamond.fill")
                                    .font(.system(.caption, design: .rounded).weight(.semibold))
                            }
                            .foregroundStyle(renderer.brushMode == .prismCrystal ? .black : .white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                renderer.brushMode == .prismCrystal ? AnyShapeStyle(Color.cyan) : AnyShapeStyle(.black.opacity(0.6)),
                                in: Capsule()
                            )
                        }
                        .accessibilityIdentifier("hud.brush.crystal")
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    VStack(spacing: 6) {
                        HStack(spacing: 8) {
                            Text("Blast")
                                .font(.system(.caption2, design: .rounded).weight(.semibold))
                                .foregroundStyle(.white.opacity(0.85))
                                .frame(width: 40, alignment: .leading)
                            Slider(value: $renderer.blastRadius, in: 1.0...6.0)
                                .tint(.orange)
                                .frame(width: 135)
                                .accessibilityIdentifier("hud.slider.blastRadius")
                            Text(String(format: "%.1f", renderer.blastRadius))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.white)
                                .frame(width: 28, alignment: .trailing)
                        }

                        HStack(spacing: 8) {
                            Text("Sun")
                                .font(.system(.caption2, design: .rounded).weight(.semibold))
                                .foregroundStyle(.white.opacity(0.85))
                                .frame(width: 40, alignment: .leading)
                            Slider(value: $renderer.sunElevation, in: 0.08...1.45)
                                .tint(.yellow)
                                .frame(width: 135)
                                .accessibilityIdentifier("hud.slider.sunElevation")
                            Text(String(format: "%.0f°", renderer.sunElevation * 180.0 / .pi))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.white)
                                .frame(width: 28, alignment: .trailing)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Button {
                        renderer.resetWorld()
                    } label: {
                        Label("Reset World", systemImage: "arrow.counterclockwise")
                            .font(.system(.caption, design: .rounded).weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.red.opacity(0.75), in: Capsule())
                    }
                    .accessibilityIdentifier("hud.button.reset")
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
        }
    }

    private var photoModeOverlay: some View {
        VStack {
            HStack {
                HStack(spacing: 8) {
                    if renderer.isCapturingPhoto {
                        ProgressView()
                            .tint(.cyan)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Text(renderer.isCapturingPhoto ? "Converging 64-Sample Path Trace…" : "Photo Ready")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.68), in: Capsule())

                Spacer()

                Button {
                    renderer.exitPhotoMode()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.black.opacity(0.68), in: Circle())
                }
                .accessibilityIdentifier("hud.photo.close")
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            Spacer()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hud.photo.overlay")
    }

    private var virtualJoystick: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.38))
                .overlay(
                    Circle()
                        .strokeBorder(.white.opacity(0.3), lineWidth: 1.5)
                )
                .frame(width: joystickRadius * 2, height: joystickRadius * 2)

            Circle()
                .fill(.white.opacity(0.86))
                .frame(width: 32, height: 32)
                .offset(joystickOffset)
        }
        .contentShape(Circle())
        .accessibilityIdentifier("hud.joystick")
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    let dist = hypot(dx, dy)
                    let maxR = joystickRadius - 10
                    let clamped = dist > maxR ? maxR / dist : 1.0
                    let ox = dx * clamped
                    let oy = dy * clamped
                    joystickOffset = CGSize(width: ox, height: oy)
                    renderer.moveInput = SIMD2<Float>(Float(ox / maxR), Float(-oy / maxR))
                }
                .onEnded { _ in
                    joystickOffset = .zero
                    renderer.moveInput = .zero
                }
        )
    }

    private func biomeIdentifier(for biome: VoxelBiome) -> String {
        switch biome {
        case .sunlitCourtyard: return "hud.biome.courtyard"
        case .neonCavern: return "hud.biome.neon"
        case .glassCathedral: return "hud.biome.cathedral"
        }
    }
}
