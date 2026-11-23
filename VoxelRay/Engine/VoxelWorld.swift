import Foundation
import Metal
import simd

/// Supported voxel sandbox environments.
public enum VoxelBiome: UInt32, CaseIterable, Identifiable, Sendable {
    case sunlitCourtyard = 0
    case neonCavern = 1
    case glassCathedral = 2

    public var id: UInt32 { rawValue }

    public var displayName: String {
        switch self {
        case .sunlitCourtyard: return "Sunlit Courtyard"
        case .neonCavern: return "Neon Cavern"
        case .glassCathedral: return "Glass Cathedral"
        }
    }

    public var shortTitle: String {
        switch self {
        case .sunlitCourtyard: return "Courtyard"
        case .neonCavern: return "Neon Cavern"
        case .glassCathedral: return "Cathedral"
        }
    }

    public var requiresPro: Bool {
        self != .sunlitCourtyard
    }

    public var defaultSeed: UInt64 {
        switch self {
        case .sunlitCourtyard: return 0x564F_5845_4C30_0001
        case .neonCavern: return 0x564F_5845_4C30_0002
        case .glassCathedral: return 0x564F_5845_4C30_0003
        }
    }

    public var defaultSunElevation: Float {
        switch self {
        case .sunlitCourtyard: return 0.78
        case .neonCavern: return 0.22
        case .glassCathedral: return 0.56
        }
    }
}

/// Packed 8-bit voxel material IDs shared with Metal shaders.
public enum VoxelMaterial: UInt8, CaseIterable, Sendable {
    case air = 0
    case travertine = 1
    case terracotta = 2
    case moss = 3
    case basalt = 4
    case gold = 5
    case chrome = 6
    case glass = 7
    case water = 8
    case neonCyan = 9
    case neonMagenta = 10
    case amberLantern = 11
    case prismCrystal = 12
}

/// Deterministic hit information returned by CPU 3D DDA raycasting.
public struct VoxelRayHit: Equatable, Sendable {
    public let voxelCoord: SIMD3<Int32>
    public let normal: SIMD3<Float>
    public let distance: Float
    public let material: VoxelMaterial
    public let hitPoint: SIMD3<Float>
}

/// Deterministic 64x32x64 procedural voxel grid with spherical destruction and brick AABB generation.
public final class VoxelWorld {
    public static let width = 64
    public static let height = 32
    public static let depth = 64
    public static let voxelCount = width * height * depth

    public static let brickSize = 4
    public static let bricksX = width / brickSize   // 16
    public static let bricksY = height / brickSize  // 8
    public static let bricksZ = depth / brickSize   // 16
    public static let brickCount = bricksX * bricksY * bricksZ // 2048

    public private(set) var biome: VoxelBiome
    public private(set) var seed: UInt64
    public private(set) var voxels: [UInt8]
    public private(set) var revision: UInt64 = 1

    public init(biome: VoxelBiome = .sunlitCourtyard, seed: UInt64? = nil) {
        self.biome = biome
        self.seed = seed ?? biome.defaultSeed
        self.voxels = [UInt8](repeating: VoxelMaterial.air.rawValue, count: Self.voxelCount)
        generate(biome: biome, seed: self.seed)
    }

    @inline(__always)
    public static func index(x: Int, y: Int, z: Int) -> Int {
        x + width * (y + height * z)
    }

    @inline(__always)
    public static func brickIndex(bx: Int, by: Int, bz: Int) -> Int {
        bx + bricksX * (by + bricksY * bz)
    }

    @inline(__always)
    public static func isInBounds(x: Int, y: Int, z: Int) -> Bool {
        x >= 0 && x < width && y >= 0 && y < height && z >= 0 && z < depth
    }

    public func voxel(x: Int, y: Int, z: Int) -> VoxelMaterial {
        guard Self.isInBounds(x: x, y: y, z: z) else { return .air }
        return VoxelMaterial(rawValue: voxels[Self.index(x: x, y: y, z: z)]) ?? .air
    }

    public func setVoxel(x: Int, y: Int, z: Int, material: VoxelMaterial) {
        guard Self.isInBounds(x: x, y: y, z: z) else { return }
        voxels[Self.index(x: x, y: y, z: z)] = material.rawValue
    }

    /// Returns the recommended initial eye & target pose for showcasing a biome.
    public static func defaultCameraPose(for biome: VoxelBiome) -> (eye: SIMD3<Float>, target: SIMD3<Float>) {
        switch biome {
        case .sunlitCourtyard:
            return (SIMD3<Float>(46.5, 17.5, 47.5), SIMD3<Float>(28.0, 6.0, 28.0))
        case .neonCavern:
            return (SIMD3<Float>(38.5, 11.0, 48.0), SIMD3<Float>(29.5, 7.0, 26.0))
        case .glassCathedral:
            return (SIMD3<Float>(40.5, 11.5, 53.5), SIMD3<Float>(30.5, 9.5, 20.0))
        }
    }

    /// Regenerates the entire world deterministically for the given biome and seed.
    public func generate(biome: VoxelBiome, seed: UInt64? = nil) {
        self.biome = biome
        self.seed = seed ?? biome.defaultSeed
        for i in 0..<Self.voxelCount {
            voxels[i] = VoxelMaterial.air.rawValue
        }

        var rng = SplitMix64(seed: self.seed)
        switch biome {
        case .sunlitCourtyard:
            buildSunlitCourtyard(rng: &rng)
        case .neonCavern:
            buildNeonCavern(rng: &rng)
        case .glassCathedral:
            buildGlassCathedral(rng: &rng)
        }
        revision &+= 1
    }

    /// Carves a spherical blast crater centered at world-space coordinates, strictly bounds-clamped.
    @discardableResult
    public func carveSphere(center: SIMD3<Float>, radius: Float) -> Int {
        guard radius > 0 else { return 0 }
        let rClamped = min(max(radius, 0.5), 16.0)
        let rSq = rClamped * rClamped

        let minX = max(0, Int(floor(center.x - rClamped)))
        let maxX = min(Self.width - 1, Int(ceil(center.x + rClamped)))
        let minY = max(1, Int(floor(center.y - rClamped))) // preserve bedrock base layer y=0
        let maxY = min(Self.height - 1, Int(ceil(center.y + rClamped)))
        let minZ = max(0, Int(floor(center.z - rClamped)))
        let maxZ = min(Self.depth - 1, Int(ceil(center.z + rClamped)))

        guard minX <= maxX, minY <= maxY, minZ <= maxZ else { return 0 }

        var carved = 0
        for z in minZ...maxZ {
            let dz = (Float(z) + 0.5) - center.z
            for y in minY...maxY {
                let dy = (Float(y) + 0.5) - center.y
                for x in minX...maxX {
                    let dx = (Float(x) + 0.5) - center.x
                    if dx * dx + dy * dy + dz * dz <= rSq {
                        let idx = Self.index(x: x, y: y, z: z)
                        if voxels[idx] != VoxelMaterial.air.rawValue {
                            voxels[idx] = VoxelMaterial.air.rawValue
                            carved += 1
                        }
                    }
                }
            }
        }
        if carved > 0 {
            revision &+= 1
        }
        return carved
    }

    /// Places a spherical brush cluster of the chosen material, strictly bounds-clamped.
    @discardableResult
    public func placeMaterialSphere(center: SIMD3<Float>, radius: Float, material: VoxelMaterial) -> Int {
        guard radius > 0, material != .air else { return 0 }
        let rClamped = min(max(radius, 0.5), 10.0)
        let rSq = rClamped * rClamped

        let minX = max(0, Int(floor(center.x - rClamped)))
        let maxX = min(Self.width - 1, Int(ceil(center.x + rClamped)))
        let minY = max(1, Int(floor(center.y - rClamped)))
        let maxY = min(Self.height - 1, Int(ceil(center.y + rClamped)))
        let minZ = max(0, Int(floor(center.z - rClamped)))
        let maxZ = min(Self.depth - 1, Int(ceil(center.z + rClamped)))

        guard minX <= maxX, minY <= maxY, minZ <= maxZ else { return 0 }

        var placed = 0
        for z in minZ...maxZ {
            let dz = (Float(z) + 0.5) - center.z
            for y in minY...maxY {
                let dy = (Float(y) + 0.5) - center.y
                for x in minX...maxX {
                    let dx = (Float(x) + 0.5) - center.x
                    if dx * dx + dy * dy + dz * dz <= rSq {
                        let idx = Self.index(x: x, y: y, z: z)
                        if voxels[idx] == VoxelMaterial.air.rawValue {
                            voxels[idx] = material.rawValue
                            placed += 1
                        }
                    }
                }
            }
        }
        if placed > 0 {
            revision &+= 1
        }
        return placed
    }

    /// Builds tight 4x4x4 brick AABBs (2048 entries) for Metal 4 hardware BVH construction & refit.
    public func buildBrickAABBs() -> [MTLAxisAlignedBoundingBox] {
        var result = [MTLAxisAlignedBoundingBox]()
        result.reserveCapacity(Self.brickCount)

        let emptyBox = MTLAxisAlignedBoundingBox(
            min: MTLPackedFloat3Make(Float.nan, Float.nan, Float.nan),
            max: MTLPackedFloat3Make(Float.nan, Float.nan, Float.nan)
        )

        for bz in 0..<Self.bricksZ {
            let zBase = bz * Self.brickSize
            for by in 0..<Self.bricksY {
                let yBase = by * Self.brickSize
                for bx in 0..<Self.bricksX {
                    let xBase = bx * Self.brickSize
                    var minX = Int.max
                    var minY = Int.max
                    var minZ = Int.max
                    var maxX = Int.min
                    var maxY = Int.min
                    var maxZ = Int.min

                    for lz in 0..<Self.brickSize {
                        let z = zBase + lz
                        for ly in 0..<Self.brickSize {
                            let y = yBase + ly
                            let rowStart = Self.index(x: xBase, y: y, z: z)
                            for lx in 0..<Self.brickSize {
                                if voxels[rowStart + lx] != 0 {
                                    let x = xBase + lx
                                    if x < minX { minX = x }
                                    if y < minY { minY = y }
                                    if z < minZ { minZ = z }
                                    if x > maxX { maxX = x }
                                    if y > maxY { maxY = y }
                                    if z > maxZ { maxZ = z }
                                }
                            }
                        }
                    }

                    if minX <= maxX {
                        result.append(
                            MTLAxisAlignedBoundingBox(
                                min: MTLPackedFloat3Make(Float(minX), Float(minY), Float(minZ)),
                                max: MTLPackedFloat3Make(Float(maxX + 1), Float(maxY + 1), Float(maxZ + 1))
                            )
                        )
                    } else {
                        result.append(emptyBox)
                    }
                }
            }
        }
        return result
    }

    /// Analytical 3D Amanatides-Woo DDA raycast matching GPU DDA traversal.
    public func raycast(origin: SIMD3<Float>, direction: SIMD3<Float>, maxDistance: Float = 200.0) -> VoxelRayHit? {
        let dirLen = simd_length(direction)
        guard dirLen > 1e-6 else { return nil }
        let dir = direction / dirLen

        let invDir = SIMD3<Float>(
            abs(dir.x) > 1e-6 ? 1.0 / dir.x : (dir.x >= 0 ? 1e30 : -1e30),
            abs(dir.y) > 1e-6 ? 1.0 / dir.y : (dir.y >= 0 ? 1e30 : -1e30),
            abs(dir.z) > 1e-6 ? 1.0 / dir.z : (dir.z >= 0 ? 1e30 : -1e30)
        )

        let boxMin = SIMD3<Float>(0, 0, 0)
        let boxMax = SIMD3<Float>(Float(Self.width), Float(Self.height), Float(Self.depth))

        let t0 = (boxMin - origin) * invDir
        let t1 = (boxMax - origin) * invDir
        let tSmaller = simd_min(t0, t1)
        let tLarger = simd_max(t0, t1)

        let tEnter = max(max(tSmaller.x, tSmaller.y), max(tSmaller.z, 0.0))
        let tExit = min(min(tLarger.x, tLarger.y), min(tLarger.z, maxDistance))
        guard tEnter < tExit else { return nil }

        let startDist = tEnter > 0 ? tEnter + 1e-4 : 0.0
        let startPos = origin + dir * startDist

        var vx = min(max(Int(floor(startPos.x)), 0), Self.width - 1)
        var vy = min(max(Int(floor(startPos.y)), 0), Self.height - 1)
        var vz = min(max(Int(floor(startPos.z)), 0), Self.depth - 1)

        var lastNormal = SIMD3<Float>(0, 1, 0)
        if tEnter > 0 {
            if tSmaller.x >= tSmaller.y && tSmaller.x >= tSmaller.z {
                lastNormal = SIMD3<Float>(dir.x > 0 ? -1 : 1, 0, 0)
            } else if tSmaller.y >= tSmaller.z {
                lastNormal = SIMD3<Float>(0, dir.y > 0 ? -1 : 1, 0)
            } else {
                lastNormal = SIMD3<Float>(0, 0, dir.z > 0 ? -1 : 1)
            }
        }

        let stepX = dir.x >= 0 ? 1 : -1
        let stepY = dir.y >= 0 ? 1 : -1
        let stepZ = dir.z >= 0 ? 1 : -1

        let nextBoundaryX = Float(vx + (stepX > 0 ? 1 : 0))
        let nextBoundaryY = Float(vy + (stepY > 0 ? 1 : 0))
        let nextBoundaryZ = Float(vz + (stepZ > 0 ? 1 : 0))

        var tMaxX = abs(dir.x) > 1e-6 ? (nextBoundaryX - origin.x) * invDir.x : 1e30
        var tMaxY = abs(dir.y) > 1e-6 ? (nextBoundaryY - origin.y) * invDir.y : 1e30
        var tMaxZ = abs(dir.z) > 1e-6 ? (nextBoundaryZ - origin.z) * invDir.z : 1e30

        let tDeltaX = abs(dir.x) > 1e-6 ? abs(invDir.x) : 1e30
        let tDeltaY = abs(dir.y) > 1e-6 ? abs(invDir.y) : 1e30
        let tDeltaZ = abs(dir.z) > 1e-6 ? abs(invDir.z) : 1e30

        var currentT = startDist

        for _ in 0..<256 {
            let mat = voxel(x: vx, y: vy, z: vz)
            if mat != .air {
                return VoxelRayHit(
                    voxelCoord: SIMD3<Int32>(Int32(vx), Int32(vy), Int32(vz)),
                    normal: lastNormal,
                    distance: currentT,
                    material: mat,
                    hitPoint: origin + dir * currentT
                )
            }

            if tMaxX < tMaxY && tMaxX < tMaxZ {
                currentT = tMaxX
                tMaxX += tDeltaX
                vx += stepX
                lastNormal = SIMD3<Float>(Float(-stepX), 0, 0)
            } else if tMaxY < tMaxZ {
                currentT = tMaxY
                tMaxY += tDeltaY
                vy += stepY
                lastNormal = SIMD3<Float>(0, Float(-stepY), 0)
            } else {
                currentT = tMaxZ
                tMaxZ += tDeltaZ
                vz += stepZ
                lastNormal = SIMD3<Float>(0, 0, Float(-stepZ))
            }

            if currentT > tExit || !Self.isInBounds(x: vx, y: vy, z: vz) {
                break
            }
        }
        return nil
    }

    // MARK: - Procedural Biome Generators

    private func fillBox(x0: Int, y0: Int, z0: Int, x1: Int, y1: Int, z1: Int, material: VoxelMaterial) {
        let minX = max(0, x0), maxX = min(Self.width - 1, x1)
        let minY = max(0, y0), maxY = min(Self.height - 1, y1)
        let minZ = max(0, z0), maxZ = min(Self.depth - 1, z1)
        guard minX <= maxX, minY <= maxY, minZ <= maxZ else { return }
        for z in minZ...maxZ {
            for y in minY...maxY {
                for x in minX...maxX {
                    voxels[Self.index(x: x, y: y, z: z)] = material.rawValue
                }
            }
        }
    }

    private func buildSunlitCourtyard(rng: inout SplitMix64) {
        // Warm travertine plaza base + stepped outer plinth
        for z in 0..<Self.depth {
            for x in 0..<Self.width {
                let checker = ((x / 2) + (z / 2)) % 2 == 0
                setVoxel(x: x, y: 0, z: z, material: checker ? .travertine : .terracotta)
                if x >= 8 && x <= 55 && z >= 8 && z <= 55 {
                    let tile: VoxelMaterial = ((x + z) % 7 == 0) ? .terracotta : .travertine
                    setVoxel(x: x, y: 1, z: z, material: tile)
                }
            }
        }

        // Recessed reflective water basin in courtyard center + stepping stones
        fillBox(x0: 23, y0: 1, z0: 23, x1: 40, y1: 1, z1: 40, material: .water)
        for p in stride(from: 24, through: 39, by: 3) {
            fillBox(x0: p, y0: 1, z0: 31, x1: p + 1, y1: 1, z1: 32, material: .travertine)
        }

        // Central golden obelisk & glowing amber brazier
        fillBox(x0: 30, y0: 1, z0: 30, x1: 33, y1: 2, z1: 33, material: .travertine)
        fillBox(x0: 31, y0: 3, z0: 31, x1: 32, y1: 10, z1: 32, material: .gold)
        fillBox(x0: 31, y0: 11, z0: 31, x1: 32, y1: 12, z1: 32, material: .amberLantern)

        // Perimeter colonnade pillars & terracotta roof entablature
        let pillarCoords = stride(from: 11, through: 52, by: 6)
        for p in pillarCoords {
            for edge in [(p, 11), (p, 52), (11, p), (52, p)] {
                fillBox(x0: edge.0, y0: 2, z0: edge.1, x1: edge.0 + 1, y1: 11, z1: edge.1 + 1, material: .travertine)
                setVoxel(x: edge.0, y: 11, z: edge.1, material: .gold)
            }
        }
        // Roof lintels & terracotta eaves
        fillBox(x0: 10, y0: 12, z0: 10, x1: 53, y1: 12, z1: 13, material: .travertine)
        fillBox(x0: 10, y0: 12, z0: 50, x1: 53, y1: 12, z1: 53, material: .travertine)
        fillBox(x0: 10, y0: 12, z0: 10, x1: 13, y1: 12, z1: 53, material: .travertine)
        fillBox(x0: 50, y0: 12, z0: 10, x1: 53, y1: 12, z1: 53, material: .travertine)

        fillBox(x0: 9, y0: 13, z0: 9, x1: 54, y1: 14, z1: 13, material: .terracotta)
        fillBox(x0: 9, y0: 13, z0: 50, x1: 54, y1: 14, z1: 54, material: .terracotta)
        fillBox(x0: 9, y0: 13, z0: 9, x1: 13, y1: 14, z1: 54, material: .terracotta)
        fillBox(x0: 50, y0: 13, z0: 9, x1: 54, y1: 14, z1: 54, material: .terracotta)

        // Garden planters with moss & cypress spires
        let planters = [(17, 17), (44, 17), (17, 44), (44, 44)]
        for (px, pz) in planters {
            fillBox(x0: px, y0: 2, z0: pz, x1: px + 3, y1: 2, z1: pz + 3, material: .terracotta)
            fillBox(x0: px + 1, y0: 2, z0: pz + 1, x1: px + 2, y1: 3, z1: pz + 2, material: .moss)
            let treeH = 5 + Int(rng.next() % 4)
            fillBox(x0: px + 1, y0: 4, z0: pz + 1, x1: px + 2, y1: 3 + treeH, z1: pz + 2, material: .moss)
            setVoxel(x: px + 1, y: 4 + treeH, z: pz + 1, material: .moss)
        }

        // Warm amber sconces on corner columns
        for (lx, lz) in [(13, 13), (50, 13), (13, 50), (50, 50)] {
            setVoxel(x: lx, y: 6, z: lz, material: .amberLantern)
        }
    }

    private func buildNeonCavern(rng: inout SplitMix64) {
        // Dark volcanic basalt floor + organic cavern walls & ceiling arches with skylight slit
        fillBox(x0: 0, y0: 0, z0: 0, x1: 63, y1: 1, z1: 63, material: .basalt)

        for z in 0..<Self.depth {
            for x in 0..<Self.width {
                let borderDist = min(min(x, 63 - x), min(z, 63 - z))
                if borderDist < 4 {
                    let wallH = 16 + Int(rng.next() % 12)
                    fillBox(x0: x, y0: 1, z0: z, x1: x, y1: wallH, z1: z, material: .basalt)
                }
                // Vaulted ceiling with open central skylight ridge for dramatic rim light
                let distCenter = abs(x - 32) + abs(z - 32)
                if distCenter > 16 {
                    let ceilY = max(21, 29 - distCenter / 5)
                    fillBox(x0: x, y0: ceilY, z0: z, x1: x, y1: 31, z1: z, material: .basalt)
                    if rng.next() % 19 == 0 {
                        let drop = 2 + Int(rng.next() % 5)
                        fillBox(x0: x, y0: max(14, ceilY - drop), z0: z, x1: x, y1: ceilY, z1: z, material: .basalt)
                    }
                }
            }
        }

        // Shallow reflective black-mirror water pool in center
        fillBox(x0: 16, y0: 1, z0: 16, x1: 47, y1: 1, z1: 47, material: .water)

        // Chrome suspended catwalks
        fillBox(x0: 14, y0: 4, z0: 30, x1: 49, y1: 4, z1: 33, material: .chrome)
        fillBox(x0: 30, y0: 4, z0: 14, x1: 33, y1: 4, z1: 49, material: .chrome)

        // Four giant basalt pylons wrapped in cyan & magenta emissive strips
        let pylons = [(18, 18), (43, 18), (18, 43), (43, 43)]
        for (idx, (px, pz)) in pylons.enumerated() {
            fillBox(x0: px, y0: 1, z0: pz, x1: px + 2, y1: 22, z1: pz + 2, material: .basalt)
            let neonMat: VoxelMaterial = (idx % 2 == 0) ? .neonCyan : .neonMagenta
            for y in stride(from: 3, through: 20, by: 3) {
                fillBox(x0: px, y0: y, z0: pz, x1: px + 2, y1: y, z1: pz + 2, material: neonMat)
            }
        }

        // Central glowing prism & neon crystal spire
        fillBox(x0: 29, y0: 2, z0: 29, x1: 34, y1: 5, z1: 34, material: .basalt)
        fillBox(x0: 30, y0: 6, z0: 30, x1: 33, y1: 14, z1: 33, material: .neonCyan)
        fillBox(x0: 31, y0: 8, z0: 31, x1: 32, y1: 18, z1: 32, material: .neonMagenta)
        setVoxel(x: 31, y: 19, z: 31, material: .prismCrystal)
        setVoxel(x: 32, y: 19, z: 32, material: .prismCrystal)

        // Scattered glowing crystal clusters along cavern floor edges
        for _ in 0..<24 {
            let cx = 6 + Int(rng.next() % 52)
            let cz = 6 + Int(rng.next() % 52)
            if abs(cx - 32) > 14 || abs(cz - 32) > 14 {
                let h = 2 + Int(rng.next() % 4)
                let mat: VoxelMaterial = (rng.next() % 2 == 0) ? .neonCyan : .neonMagenta
                fillBox(x0: cx, y0: 2, z0: cz, x1: cx, y1: 2 + h, z1: cz, material: mat)
            }
        }
    }

    private func buildGlassCathedral(rng: inout SplitMix64) {
        // Pale marble/travertine & chrome inlaid nave floor
        for z in 0..<Self.depth {
            for x in 0..<Self.width {
                let border = (x % 8 == 0 || z % 8 == 0)
                setVoxel(x: x, y: 0, z: z, material: border ? .gold : .travertine)
                if x >= 10 && x <= 53 && z >= 8 && z <= 55 {
                    setVoxel(x: x, y: 1, z: z, material: (x == 31 || x == 32) ? .amberLantern : .travertine)
                }
            }
        }

        // Flanking water reflection channels inside the nave
        fillBox(x0: 24, y0: 1, z0: 12, x1: 26, y1: 1, z1: 50, material: .water)
        fillBox(x0: 37, y0: 1, z0: 12, x1: 39, y1: 1, z1: 50, material: .water)

        // Repeating Gothic gold ribs + glass curtain walls + arched vaults
        for z in stride(from: 14, through: 50, by: 9) {
            fillBox(x0: 16, y0: 2, z0: z, x1: 18, y1: 18, z1: z + 1, material: .gold)
            fillBox(x0: 45, y0: 2, z0: z, x1: 47, y1: 18, z1: z + 1, material: .gold)

            // Vault arch spanning x = 18..45
            for x in 18...45 {
                let norm = Float(x - 31) / 14.0
                let archY = Int(round(25.0 - norm * norm * 7.0))
                fillBox(x0: x, y0: archY, z0: z, x1: x, y1: archY + 1, z1: z + 1, material: (x % 4 == 0) ? .gold : .glass)
            }
        }

        // Translucent dielectric glass clerestory walls
        for z in 14...50 {
            if z % 9 > 1 {
                fillBox(x0: 16, y0: 2, z0: z, x1: 16, y1: 16, z1: z, material: .glass)
                fillBox(x0: 47, y0: 2, z0: z, x1: 47, y1: 16, z1: z, material: .glass)
                if z % 3 == 0 {
                    fillBox(x0: 16, y0: 6, z0: z, x1: 16, y1: 12, z1: z, material: .prismCrystal)
                    fillBox(x0: 47, y0: 6, z0: z, x1: 47, y1: 12, z1: z, material: .prismCrystal)
                }
            }
        }

        // Soaring Prism Crystal high altar spire & rose window halo
        fillBox(x0: 29, y0: 2, z0: 16, x1: 34, y1: 4, z1: 21, material: .gold)
        fillBox(x0: 30, y0: 5, z0: 17, x1: 33, y1: 18, z1: 20, material: .prismCrystal)
        fillBox(x0: 31, y0: 19, z0: 18, x1: 32, y1: 26, z1: 19, material: .glass)
        setVoxel(x: 31, y: 27, z: 18, material: .amberLantern)

        // Crystalline buttress accents
        for _ in 0..<12 {
            let sideX = (rng.next() % 2 == 0) ? 20 : 43
            let cz = 16 + Int(rng.next() % 32)
            fillBox(x0: sideX, y0: 2, z0: cz, x1: sideX, y1: 5, z1: cz, material: .prismCrystal)
        }
    }
}

/// Deterministic 64-bit SplitMix PRNG for reproducible procedural worlds.
public struct SplitMix64 {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
