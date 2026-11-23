import XCTest
import simd
@testable import VoxelRay

final class VoxelWorldTests: XCTestCase {
    func testGridBoundsSafety() {
        let world = VoxelWorld(biome: .sunlitCourtyard)
        XCTAssertEqual(world.voxels.count, VoxelWorld.voxelCount)
        XCTAssertEqual(world.voxel(x: -1, y: 0, z: 0), .air)
        XCTAssertEqual(world.voxel(x: 64, y: 0, z: 0), .air)
        XCTAssertEqual(world.voxel(x: 0, y: -5, z: 0), .air)
        XCTAssertEqual(world.voxel(x: 0, y: 32, z: 0), .air)
        XCTAssertEqual(world.voxel(x: 0, y: 0, z: 64), .air)

        world.setVoxel(x: -10, y: 50, z: 99, material: .gold)
        XCTAssertEqual(world.voxels.count, VoxelWorld.voxelCount)

        // Bedrock base at y=0 remains protected against carving
        let carved = world.carveSphere(center: SIMD3<Float>(32, 0, 32), radius: 2.0)
        XCTAssertGreaterThanOrEqual(carved, 0)
        XCTAssertNotEqual(world.voxel(x: 32, y: 0, z: 32), .air)
    }

    func testSeedDeterminismAcrossBiomes() {
        for biome in VoxelBiome.allCases {
            let worldA = VoxelWorld(biome: biome)
            let worldB = VoxelWorld(biome: biome)
            XCTAssertEqual(worldA.voxels, worldB.voxels, "World bytes must be deterministic for \(biome)")
            XCTAssertEqual(worldA.buildBrickAABBs().count, VoxelWorld.brickCount)

            let pose = VoxelWorld.defaultCameraPose(for: biome)
            XCTAssertEqual(
                worldA.voxel(x: Int(floor(pose.eye.x)), y: Int(floor(pose.eye.y)), z: Int(floor(pose.eye.z))),
                .air,
                "Default camera eye for \(biome) must be in open air"
            )
            let forwardHit = worldA.raycast(origin: pose.eye, direction: simd_normalize(pose.target - pose.eye))
            XCTAssertNotNil(forwardHit, "Default camera pose for \(biome) must frame solid geometry")
        }
    }

    #if targetEnvironment(simulator)
    func testAnalyticalCPUVersusGPURaycastParity() throws {
        guard let renderer = Renderer() else {
            XCTFail("Renderer unavailable")
            return
        }

        for biome in VoxelBiome.allCases {
            renderer.selectBiome(biome)
            let pose = VoxelWorld.defaultCameraPose(for: biome)
            renderer.camera.lookAt(eye: pose.eye, target: pose.target)

            var rays = [(origin: SIMD3<Float>, direction: SIMD3<Float>)]()
            let sampleUVs: [SIMD2<Float>] = [
                SIMD2<Float>(0.50, 0.50),
                SIMD2<Float>(0.35, 0.48),
                SIMD2<Float>(0.65, 0.55),
                SIMD2<Float>(0.50, 0.85),
                SIMD2<Float>(0.50, 0.05), // typically sky miss
                SIMD2<Float>(0.15, 0.25),
            ]
            for uv in sampleUVs {
                rays.append((origin: renderer.camera.position, direction: renderer.camera.rayDirection(normalizedScreenPoint: uv)))
            }

            let gpuResults = renderer.gpuRaycastParity(rays: rays)
            XCTAssertEqual(gpuResults.count, rays.count)

            for (idx, ray) in rays.enumerated() {
                let cpuHit = renderer.world.raycast(origin: ray.origin, direction: ray.direction)
                let gpuHit = gpuResults[idx]

                if let cpuHit = cpuHit {
                    XCTAssertEqual(gpuHit.voxelAndHit.w, 1, "Biome \(biome) ray \(idx) should hit on GPU")
                    XCTAssertEqual(gpuHit.voxelAndHit.x, cpuHit.voxelCoord.x)
                    XCTAssertEqual(gpuHit.voxelAndHit.y, cpuHit.voxelCoord.y)
                    XCTAssertEqual(gpuHit.voxelAndHit.z, cpuHit.voxelCoord.z)
                    XCTAssertEqual(gpuHit.materialAndPad.x, UInt32(cpuHit.material.rawValue))
                } else {
                    XCTAssertEqual(gpuHit.voxelAndHit.w, 0, "Biome \(biome) ray \(idx) should miss on GPU")
                }
            }
        }
    }
    #endif
}
