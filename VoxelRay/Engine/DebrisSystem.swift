import Foundation
import simd
import CoreGraphics
import SwiftUI

/// Lightweight 3D physics debris burst & screen-space projection engine for voxel destruction feel.
public final class DebrisSystem: ObservableObject {
    public struct Particle: Sendable {
        public var position: SIMD3<Float>
        public var velocity: SIMD3<Float>
        public var size: Float
        public var color: SIMD3<Float>
        public var age: Float
        public var lifetime: Float
        public var spinAngle: Float
        public var spinSpeed: Float
        public var emissive: Bool
    }

    public struct ProjectedParticle: Identifiable, Sendable {
        public let id: Int
        public let screenPos: CGPoint
        public let pixelSize: CGFloat
        public let color: SIMD3<Float>
        public let alpha: Double
        public let rotation: Double
        public let depth: Float
        public let emissive: Bool
    }

    @Published public private(set) var tickCounter: UInt64 = 0
    public private(set) var particles: [Particle] = []

    private var rng = SplitMix64(seed: 0x4445_4252_4953_0001)

    public init() {}

    public func clear() {
        particles.removeAll(keepingCapacity: true)
        tickCounter &+= 1
    }

    private func nextUnit() -> Float {
        Float(rng.next() & 0x00FF_FFFF) / Float(0x0100_0000)
    }

    public func spawnBurst(
        at origin: SIMD3<Float>,
        material: VoxelMaterial,
        count: Int = 20,
        blastRadius: Float = 3.0,
        isPlace: Bool = false
    ) {
        let baseColor = Self.swatchColor(for: material)
        let isEmissive = (material == .neonCyan || material == .neonMagenta || material == .amberLantern || material == .prismCrystal)
        let actualCount = min(max(count, 6), 34)
        let speedScale = isPlace ? Float(3.8) : (4.5 + blastRadius * 1.45)

        if particles.count > 160 {
            particles.removeFirst(particles.count - 160)
        }

        for _ in 0..<actualCount {
            let theta = nextUnit() * Float.pi * 2.0
            let up = 0.25 + nextUnit() * 0.95
            let radial = sqrt(max(0.05, 1.0 - up * up * 0.5))
            let dir = simd_normalize(SIMD3<Float>(cos(theta) * radial, up, sin(theta) * radial))
            let speed = speedScale * (0.55 + nextUnit() * 0.85)
            let jitterPos = origin + SIMD3<Float>((nextUnit() - 0.5) * 0.8, nextUnit() * 0.6, (nextUnit() - 0.5) * 0.8)
            let shade = 0.82 + nextUnit() * 0.36

            particles.append(Particle(
                position: jitterPos,
                velocity: dir * speed,
                size: isPlace ? (0.18 + nextUnit() * 0.16) : (0.24 + nextUnit() * 0.30),
                color: simd_clamp(baseColor * shade, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1)),
                age: 0,
                lifetime: 0.72 + nextUnit() * 0.45,
                spinAngle: nextUnit() * Float.pi * 2.0,
                spinSpeed: (nextUnit() - 0.5) * 14.0,
                emissive: isEmissive
            ))
        }
        tickCounter &+= 1
    }

    public func step(dt: Float) {
        guard !particles.isEmpty else { return }
        let clampedDt = min(max(dt, 0.001), 0.05)
        let gravity: Float = -24.0
        var idx = particles.count - 1
        while idx >= 0 {
            particles[idx].age += clampedDt
            if particles[idx].age >= particles[idx].lifetime {
                particles.remove(at: idx)
            } else {
                particles[idx].velocity.y += gravity * clampedDt
                particles[idx].position += particles[idx].velocity * clampedDt
                particles[idx].spinAngle += particles[idx].spinSpeed * clampedDt

                // Elastic floor bounce against plaza level
                if particles[idx].position.y < 1.35 {
                    particles[idx].position.y = 1.35
                    if particles[idx].velocity.y < 0 {
                        particles[idx].velocity.y = -particles[idx].velocity.y * 0.42
                        particles[idx].velocity.x *= 0.82
                        particles[idx].velocity.z *= 0.82
                    }
                }
            }
            idx -= 1
        }
        tickCounter &+= 1
    }

    public func project(camera: Camera, viewSize: CGSize) -> [ProjectedParticle] {
        guard !particles.isEmpty, viewSize.width > 0, viewSize.height > 0 else { return [] }
        let fwd = camera.forward
        let rgt = camera.right
        let up = camera.up
        let tanHalfFov = tan(camera.fovY * 0.5)
        let aspect = Float(viewSize.width / max(viewSize.height, 1.0))

        var out = [ProjectedParticle]()
        out.reserveCapacity(particles.count)

        for (idx, p) in particles.enumerated() {
            let rel = p.position - camera.position
            let z = simd_dot(rel, fwd)
            guard z > 0.35 && z < 160.0 else { continue }

            let xProj = simd_dot(rel, rgt) / (z * aspect * tanHalfFov)
            let yProj = simd_dot(rel, up) / (z * tanHalfFov)
            guard abs(xProj) < 1.2 && abs(yProj) < 1.2 else { continue }

            let sx = (CGFloat(xProj) * 0.5 + 0.5) * viewSize.width
            let sy = (0.5 - CGFloat(yProj) * 0.5) * viewSize.height
            let pxSize = CGFloat((p.size / (z * tanHalfFov)) * Float(viewSize.height) * 0.55)
            guard pxSize > 1.2 else { continue }

            let lifeFrac = min(max(p.age / max(p.lifetime, 0.01), 0), 1)
            let alpha = Double(1.0 - lifeFrac * lifeFrac)

            out.append(ProjectedParticle(
                id: idx,
                screenPos: CGPoint(x: sx, y: sy),
                pixelSize: min(max(pxSize, 2.0), 48.0),
                color: p.color,
                alpha: alpha,
                rotation: Double(p.spinAngle),
                depth: z,
                emissive: p.emissive
            ))
        }
        return out.sorted { $0.depth > $1.depth }
    }

    public static func swatchColor(for material: VoxelMaterial) -> SIMD3<Float> {
        switch material {
        case .travertine: return SIMD3<Float>(0.90, 0.82, 0.68)
        case .terracotta: return SIMD3<Float>(0.84, 0.42, 0.25)
        case .moss: return SIMD3<Float>(0.30, 0.72, 0.34)
        case .basalt: return SIMD3<Float>(0.26, 0.28, 0.34)
        case .gold: return SIMD3<Float>(1.00, 0.82, 0.32)
        case .chrome: return SIMD3<Float>(0.88, 0.93, 0.98)
        case .glass: return SIMD3<Float>(0.76, 0.94, 1.00)
        case .water: return SIMD3<Float>(0.24, 0.82, 0.94)
        case .neonCyan: return SIMD3<Float>(0.22, 0.98, 1.00)
        case .neonMagenta: return SIMD3<Float>(1.00, 0.32, 0.84)
        case .amberLantern: return SIMD3<Float>(1.00, 0.78, 0.30)
        case .prismCrystal: return SIMD3<Float>(0.68, 0.92, 1.00)
        case .air: return SIMD3<Float>(0.92, 0.92, 0.95)
        }
    }
}
