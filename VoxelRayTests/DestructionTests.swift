import XCTest
import simd
@testable import VoxelRay

final class DestructionTests: XCTestCase {
    func testRapidRandomizedSphericalCarvingBoundsAndValidity() {
        let world = VoxelWorld(biome: .sunlitCourtyard)
        let originalY0 = (0..<VoxelWorld.depth).flatMap { z in
            (0..<VoxelWorld.width).map { x in world.voxel(x: x, y: 0, z: z) }
        }

        var rng = SplitMix64(seed: 0xDEAD_BEEF_CAFE_0001)
        func nextFloat(_ lo: Float, _ hi: Float) -> Float {
            let u = Float(rng.next() & 0x00FF_FFFF) / Float(0x0100_0000)
            return lo + u * (hi - lo)
        }

        // Include explicit boundary edge cases before 96 randomized blasts
        let forcedCenters: [SIMD3<Float>] = [
            SIMD3<Float>(-2, -1, -2),
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(63, 31, 63),
            SIMD3<Float>(66, 35, 66),
        ]
        for c in forcedCenters {
            _ = world.carveSphere(center: c, radius: 4.5)
        }

        for _ in 0..<96 {
            let cx = nextFloat(-4.0, 68.0)
            let cy = nextFloat(-2.0, 34.0)
            let cz = nextFloat(-4.0, 68.0)
            let r = nextFloat(0.5, 10.0)
            _ = world.carveSphere(center: SIMD3<Float>(cx, cy, cz), radius: r)
        }

        XCTAssertEqual(world.voxels.count, VoxelWorld.voxelCount)

        // All material IDs remain valid
        for byte in world.voxels {
            XCTAssertNotNil(VoxelMaterial(rawValue: byte), "Invalid voxel material byte \(byte)")
        }

        // Bedrock base layer y=0 remains intact
        var idx = 0
        for z in 0..<VoxelWorld.depth {
            for x in 0..<VoxelWorld.width {
                XCTAssertEqual(world.voxel(x: x, y: 0, z: z), originalY0[idx])
                idx += 1
            }
        }

        // Brick AABBs remain valid 2048 entries
        let aabbs = world.buildBrickAABBs()
        XCTAssertEqual(aabbs.count, VoxelWorld.brickCount)
        var nonEmptyBricks = 0
        for box in aabbs where !box.min.x.isNaN {
            nonEmptyBricks += 1
            XCTAssertGreaterThanOrEqual(box.min.x, 0)
            XCTAssertGreaterThanOrEqual(box.min.y, 0)
            XCTAssertGreaterThanOrEqual(box.min.z, 0)
            XCTAssertLessThanOrEqual(box.max.x, Float(VoxelWorld.width))
            XCTAssertLessThanOrEqual(box.max.y, Float(VoxelWorld.height))
            XCTAssertLessThanOrEqual(box.max.z, Float(VoxelWorld.depth))
            XCTAssertLessThan(box.min.x, box.max.x)
            XCTAssertLessThan(box.min.y, box.max.y)
            XCTAssertLessThan(box.min.z, box.max.z)
        }
        XCTAssertGreaterThan(nonEmptyBricks, 0)

        // Post-carve raycast still functions cleanly
        let pose = VoxelWorld.defaultCameraPose(for: .sunlitCourtyard)
        let dir = simd_normalize(SIMD3<Float>(32, 0.5, 32) - pose.eye)
        XCTAssertNotNil(world.raycast(origin: pose.eye, direction: dir))
    }

    func testTapToDestroyCarvesAndResetRestoresExactWorld() throws {
        guard let renderer = Renderer() else {
            XCTFail("Renderer unavailable")
            return
        }

        let initialSnapshot = renderer.world.voxels
        renderer.blastRadius = 3.5

        let carved = renderer.handleViewportTap(at: SIMD2<Float>(0.5, 0.5), isPrismUnlocked: false)
        XCTAssertTrue(carved, "Center viewport tap should hit and carve courtyard geometry")
        XCTAssertGreaterThan(renderer.lastCarvedVoxelCount, 0)
        XCTAssertNotEqual(renderer.world.voxels, initialSnapshot)
        XCTAssertEqual(renderer.camera.frameIndex, 0)

        renderer.resetWorld()
        XCTAssertEqual(renderer.world.voxels, initialSnapshot)
        XCTAssertEqual(renderer.camera.frameIndex, 0)
    }

    func testOpaquePhotoImageGenerationForFreeAndPro() {
        let w = 160
        let h = 90
        let bytes = [UInt8](repeating: 180, count: w * h * 4)

        let freeImg = Renderer.buildOpaqueImage(rgbaBytes: bytes, width: w, height: h, addWatermark: true)
        XCTAssertNotNil(freeImg)
        XCTAssertEqual(Int(freeImg!.size.width), w)
        XCTAssertEqual(Int(freeImg!.size.height), h)

        let proImg = Renderer.buildOpaqueImage(rgbaBytes: bytes, width: w, height: h, addWatermark: false)
        XCTAssertNotNil(proImg)
        XCTAssertEqual(Int(proImg!.size.width), w)
        XCTAssertEqual(Int(proImg!.size.height), h)
    }
}
