import SwiftUI

/// Compact landscape HUD overlay for camera navigation and real-time ray-tracing telemetry.
public struct HUDView: View {
    @ObservedObject public var renderer: Renderer
    @State private var joystickOffset: CGSize = .zero

    private let joystickRadius: CGFloat = 44

    public init(renderer: Renderer) {
        self.renderer = renderer
    }

    public var body: some View {
        ZStack {
            VStack {
                HStack(spacing: 10) {
                    Label("VoxelRay", systemImage: "cube.transparent.fill")
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())

                    Text(String(format: "%.0f FPS", renderer.fps))
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.cyan)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.55), in: Capsule())
                        .accessibilityIdentifier("hud.fps")

                    Text(renderer.thermalBadgeText)
                        .font(.system(.caption2, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.55), in: Capsule())
                        .accessibilityIdentifier("hud.metalfx.badge")

                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)

                Spacer()

                HStack(alignment: .bottom) {
                    virtualJoystick
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hud.root")
    }

    private var virtualJoystick: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.35))
                .overlay(
                    Circle()
                        .strokeBorder(.white.opacity(0.28), lineWidth: 1.5)
                )
                .frame(width: joystickRadius * 2, height: joystickRadius * 2)

            Circle()
                .fill(.white.opacity(0.85))
                .frame(width: 34, height: 34)
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
}
