import SwiftUI

/// Compact landscape HUD overlay with isolated 3D debris canvas, free creative brushes,
/// undo stack, lighting mood presets, spatial sound toggle, and live Pro previews.
public struct HUDView: View {
    @ObservedObject public var renderer: Renderer
    public var isProUnlocked: Bool
    public var isCrystalUnlocked: Bool
    public var onSelectBiome: (VoxelBiome) -> Void
    public var onSelectCrystalBrush: () -> Void
    public var onOpenPaywall: () -> Void

    @State private var joystickOffset: CGSize = .zero
    private let joystickRadius: CGFloat = 38

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
            DebrisCanvasOverlay(renderer: renderer)
                .allowsHitTesting(false)

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
            // Top bar: strict single-line pills fitting seamlessly on both 13 mini and Pro Max
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "cube.transparent.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.cyan)
                    Text("VoxelRay")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())

                Text(String(format: "%.0f FPS", renderer.fps))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.cyan)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.60), in: Capsule())
                    .accessibilityIdentifier("hud.fps")

                Text(renderer.thermalBadgeText)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.60), in: Capsule())
                    .accessibilityIdentifier("hud.metalfx.badge")

                Spacer(minLength: 4)

                // Biome switcher pills
                HStack(spacing: 5) {
                    ForEach(VoxelBiome.allCases) { biome in
                        let locked = biome.requiresPro && !isProUnlocked
                        let selected = renderer.activeBiome == biome
                        Button {
                            renderer.sound.playUIButton()
                            onSelectBiome(biome)
                        } label: {
                            HStack(spacing: 3) {
                                if locked {
                                    Image(systemName: "lock.fill")
                                        .font(.system(size: 9, weight: .bold))
                                }
                                Text(biome.shortTitle)
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                            }
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundStyle(selected ? .black : .white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                selected ? AnyShapeStyle(Color.cyan) : AnyShapeStyle(.black.opacity(0.58)),
                                in: Capsule()
                            )
                        }
                        .accessibilityIdentifier(biomeIdentifier(for: biome))
                    }
                }

                MuteToggleButton(sound: renderer.sound)

                Button {
                    renderer.sound.playUIButton()
                    onOpenPaywall()
                } label: {
                    Label(isProUnlocked ? "Studio" : "Pro", systemImage: "sparkles")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            LinearGradient(colors: [.yellow, .orange], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: Capsule()
                        )
                }
                .accessibilityIdentifier("hud.button.pro")

                Button {
                    renderer.enterPhotoMode(isProUnlocked: isProUnlocked)
                } label: {
                    Label("Photo Mode", systemImage: "camera.aperture")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.indigo.opacity(0.88), in: Capsule())
                }
                .accessibilityIdentifier("hud.button.photoMode")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            // Contextual non-intrusive status strip (live preview, toast, combo, or first-time tip)
            centerBannerStrip
                .padding(.top, 6)

            Spacer()

            // Bottom bar: Left joystick + brush strip, Right lighting/blast controls + Undo & Reset
            HStack(alignment: .bottom, spacing: 10) {
                HStack(alignment: .bottom, spacing: 10) {
                    virtualJoystick

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 5) {
                            brushButton(mode: .carve, locked: false, identifier: "hud.brush.carve") {
                                renderer.brushMode = .carve
                                renderer.sound.playUIButton()
                            }
                            brushButton(mode: .gold, locked: false, identifier: "hud.brush.gold") {
                                renderer.brushMode = .gold
                                renderer.sound.playUIButton()
                            }
                            brushButton(mode: .neonCyan, locked: false, identifier: "hud.brush.neon") {
                                renderer.brushMode = .neonCyan
                                renderer.sound.playUIButton()
                            }
                        }
                        HStack(spacing: 5) {
                            brushButton(mode: .glass, locked: false, identifier: "hud.brush.glass") {
                                renderer.brushMode = .glass
                                renderer.sound.playUIButton()
                            }
                            brushButton(mode: .prismCrystal, locked: !isCrystalUnlocked, identifier: "hud.brush.crystal") {
                                renderer.sound.playUIButton()
                                onSelectCrystalBrush()
                            }
                        }
                    }
                }

                Spacer(minLength: 6)

                VStack(alignment: .trailing, spacing: 6) {
                    VStack(spacing: 5) {
                        HStack(spacing: 6) {
                            Text("Blast")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.86))
                                .frame(width: 32, alignment: .leading)
                            Slider(value: $renderer.blastRadius, in: 1.0...6.0)
                                .tint(.orange)
                                .frame(width: 122)
                                .accessibilityIdentifier("hud.slider.blastRadius")
                            Text(String(format: "%.1f", renderer.blastRadius))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white)
                                .frame(width: 26, alignment: .trailing)
                        }

                        HStack(spacing: 6) {
                            Text("Sun")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.86))
                                .frame(width: 32, alignment: .leading)
                            Slider(value: $renderer.sunElevation, in: 0.08...1.45)
                                .tint(.yellow)
                                .frame(width: 122)
                                .accessibilityIdentifier("hud.slider.sunElevation")
                            Text(String(format: "%.0f°", renderer.sunElevation * 180.0 / .pi))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white)
                                .frame(width: 26, alignment: .trailing)
                        }

                        HStack(spacing: 4) {
                            ForEach(TimeOfDayPreset.allCases) { preset in
                                let active = abs(renderer.sunElevation - preset.sunElevation) < 0.06
                                Button {
                                    renderer.applyTimePreset(preset)
                                } label: {
                                    Text(preset.title)
                                        .font(.system(size: 9, weight: .bold, design: .rounded))
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                        .foregroundStyle(active ? .black : .white.opacity(0.9))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(
                                            active ? Color.yellow : Color.white.opacity(0.14),
                                            in: Capsule()
                                        )
                                }
                                .accessibilityIdentifier("hud.time.\(preset.rawValue)")
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    HStack(spacing: 6) {
                        Button {
                            _ = renderer.undoLastAction()
                        } label: {
                            Label("Undo", systemImage: "arrow.uturn.backward")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .foregroundStyle(.white.opacity(renderer.canUndo ? 1.0 : 0.45))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.black.opacity(0.65), in: Capsule())
                        }
                        .disabled(!renderer.canUndo)
                        .accessibilityIdentifier("hud.button.undo")

                        Button {
                            renderer.resetWorld()
                        } label: {
                            Label("Reset World", systemImage: "arrow.counterclockwise")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.red.opacity(0.78), in: Capsule())
                        }
                        .accessibilityIdentifier("hud.button.reset")
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private var centerBannerStrip: some View {
        VStack(spacing: 4) {
            if let previewBiome = renderer.previewBiome {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.yellow)
                    Text("Previewing \(previewBiome.displayName) · \(renderer.previewSecondsRemaining)s")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Button("Unlock Pro") {
                        onOpenPaywall()
                    }
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Color.cyan, in: Capsule())
                    .accessibilityIdentifier("hud.preview.unlock")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.black.opacity(0.72), in: Capsule())
                .accessibilityIdentifier("hud.preview.banner")
            }

            if let toast = renderer.activeToastText {
                Text(toast)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.yellow, in: Capsule())
                    .transition(.opacity)
            } else if let banner = renderer.impactBannerText {
                Text(banner)
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 4)
                    .background(.orange.opacity(0.86), in: Capsule())
                    .allowsHitTesting(false)
            } else if !renderer.hasInteracted {
                Text("Tap structures to blast  •  Drag to look  •  Left stick to fly")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.94))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.55), in: Capsule())
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("hud.onboarding.tip")
            }
        }
    }

    private func brushButton(
        mode: VoxelBrushMode,
        locked: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        let selected = renderer.brushMode == mode
        let activeColor: Color = (mode == .carve) ? .orange : (mode == .gold ? .yellow : (mode == .glass ? .mint : .cyan))
        return Button(action: action) {
            HStack(spacing: 3) {
                if locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .bold))
                } else {
                    Image(systemName: mode.systemImage)
                        .font(.system(size: 10, weight: .bold))
                }
                Text(mode.title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(selected ? .black : .white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                selected ? AnyShapeStyle(activeColor) : AnyShapeStyle(.black.opacity(0.62)),
                in: Capsule()
            )
        }
        .accessibilityIdentifier(identifier)
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
                .fill(.black.opacity(0.42))
                .overlay(
                    Circle()
                        .strokeBorder(.white.opacity(0.32), lineWidth: 1.5)
                )
                .frame(width: joystickRadius * 2, height: joystickRadius * 2)

            Circle()
                .fill(.white.opacity(0.88))
                .frame(width: 28, height: 28)
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
                    let maxR = joystickRadius - 9
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

private struct MuteToggleButton: View {
    @ObservedObject var sound: SoundEngine

    var body: some View {
        Button {
            _ = sound.toggleMute()
        } label: {
            Image(systemName: sound.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(sound.isMuted ? .white.opacity(0.55) : .cyan)
                .padding(6)
                .background(.black.opacity(0.60), in: Circle())
        }
        .accessibilityIdentifier("hud.button.mute")
        .accessibilityLabel(sound.isMuted ? "Unmute Audio" : "Mute Audio")
    }
}

private struct DebrisCanvasOverlay: View {
    let renderer: Renderer
    @ObservedObject private var debris: DebrisSystem

    init(renderer: Renderer) {
        self.renderer = renderer
        self.debris = renderer.debris
    }

    var body: some View {
        Canvas { ctx, size in
            _ = debris.tickCounter
            let projected = debris.project(camera: renderer.camera, viewSize: size)
            for p in projected {
                var innerCtx = ctx
                innerCtx.opacity = p.alpha
                innerCtx.translateBy(x: p.screenPos.x, y: p.screenPos.y)
                innerCtx.rotate(by: Angle(radians: p.rotation))
                let half = p.pixelSize * 0.5
                let rect = CGRect(x: -half, y: -half, width: p.pixelSize, height: p.pixelSize)
                let color = Color(
                    red: Double(p.color.x),
                    green: Double(p.color.y),
                    blue: Double(p.color.z)
                )
                if p.emissive {
                    let glowRect = rect.insetBy(dx: -p.pixelSize * 0.35, dy: -p.pixelSize * 0.35)
                    innerCtx.fill(Path(ellipseIn: glowRect), with: .color(color.opacity(0.35)))
                }
                innerCtx.fill(Path(roundedRect: rect, cornerRadius: max(1.0, p.pixelSize * 0.14)), with: .color(color))
                innerCtx.stroke(
                    Path(roundedRect: rect, cornerRadius: max(1.0, p.pixelSize * 0.14)),
                    with: .color(.white.opacity(0.35)),
                    lineWidth: 0.75
                )
            }
        }
        .ignoresSafeArea()
    }
}
