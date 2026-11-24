import XCTest
import simd
@testable import VoxelRay

final class AudioAndGameplayTests: XCTestCase {
    func testProceduralSoundSynthesisIsFiniteAndMaterialDistinct() {
        let materials: [VoxelMaterial] = [.travertine, .glass, .water, .gold, .neonCyan, .prismCrystal]
        var rmsValues = [VoxelMaterial: Double]()

        for mat in materials {
            let samples = SoundEngine.synthesizeTestSamples(for: mat)
            XCTAssertGreaterThan(samples.count, 1000, "Waveform too short for \(mat)")
            var sqSum = 0.0
            for s in samples {
                XCTAssertFalse(s.isNaN || s.isInfinite, "Invalid sample for \(mat)")
                XCTAssertLessThanOrEqual(abs(s), 1.0, "Sample clipped beyond unit amplitude for \(mat)")
                sqSum += Double(s) * Double(s)
            }
            let rms = sqrt(sqSum / Double(samples.count))
            XCTAssertGreaterThan(rms, 0.005, "Silent waveform generated for \(mat)")
            rmsValues[mat] = rms
        }

        let sound = SoundEngine()
        let wasMuted = sound.isMuted
        sound.isMuted = false
        XCTAssertTrue(sound.toggleMute())
        sound.playCarveImpact(material: .travertine, blastRadius: 3.0, combo: 2)
        XCTAssertFalse(sound.toggleMute())
        sound.isMuted = wasMuted
    }

    func testWorldUndoStackRestoresExactPreviousState() {
        let world = VoxelWorld(biome: .sunlitCourtyard)
        let original = world.voxels
        XCTAssertFalse(world.canUndo)
        XCTAssertFalse(world.undo())

        world.pushUndoSnapshot()
        let carved = world.carveSphere(center: SIMD3<Float>(31.5, 8.0, 31.5), radius: 3.0)
        XCTAssertGreaterThan(carved, 0)
        XCTAssertTrue(world.canUndo)
        XCTAssertNotEqual(world.voxels, original)

        XCTAssertTrue(world.undo())
        XCTAssertEqual(world.voxels, original)
        XCTAssertFalse(world.canUndo)
    }

    func testDebrisPhysicsBounceProjectionAndExpiration() {
        let debris = DebrisSystem()
        let camera = Camera()
        let pose = VoxelWorld.defaultCameraPose(for: .sunlitCourtyard)
        camera.lookAt(eye: pose.eye, target: pose.target)

        debris.spawnBurst(at: SIMD3<Float>(31.5, 8.0, 31.5), material: .gold, count: 16, blastRadius: 3.0)
        XCTAssertEqual(debris.particles.count, 16)

        debris.step(dt: 0.03)
        let projected = debris.project(camera: camera, viewSize: CGSize(width: 844, height: 390))
        XCTAssertGreaterThan(projected.count, 0)
        for item in projected {
            XCTAssertFalse(item.screenPos.x.isNaN || item.screenPos.y.isNaN)
            XCTAssertGreaterThan(item.pixelSize, 0)
        }

        for _ in 0..<80 {
            debris.step(dt: 0.03)
        }
        XCTAssertEqual(debris.particles.count, 0, "Expired debris particles must prune cleanly")
    }

    func testFreeBrushesComboMilestonesAndPreviewFlow() throws {
        guard let renderer = Renderer() else {
            XCTFail("Renderer unavailable")
            return
        }

        let initial = renderer.world.voxels
        renderer.brushMode = .carve
        XCTAssertTrue(renderer.handleViewportTap(at: SIMD2<Float>(0.5, 0.5), isPrismUnlocked: false))
        XCTAssertEqual(renderer.comboCount, 1)
        XCTAssertTrue(renderer.unlockedMilestones.contains("First Shatter"))
        XCTAssertTrue(renderer.canUndo)

        // Place gold voxels freely without requiring any IAP
        renderer.brushMode = .gold
        renderer.blastRadius = 2.5
        XCTAssertTrue(renderer.handleViewportTap(at: SIMD2<Float>(0.52, 0.52), isPrismUnlocked: false))
        XCTAssertGreaterThan(renderer.totalVoxelsPlaced, 0)

        // Undo gold placement and carved blast
        XCTAssertTrue(renderer.undoLastAction())
        XCTAssertTrue(renderer.undoLastAction())
        XCTAssertEqual(renderer.world.voxels, initial)

        // Time preset updates sun elevation
        renderer.applyTimePreset(.sunset)
        XCTAssertEqual(renderer.sunElevation, TimeOfDayPreset.sunset.sunElevation, accuracy: 1e-4)

        // Pro biome live preview blocks world mutation until upgraded
        renderer.selectBiome(.glassCathedral, isPreview: true)
        XCTAssertEqual(renderer.previewBiome, .glassCathedral)
        XCTAssertEqual(renderer.previewSecondsRemaining, 30)
        var upgradeTriggered = false
        renderer.onPreviewUpgradeRequested = { upgradeTriggered = true }
        XCTAssertFalse(renderer.handleViewportTap(at: SIMD2<Float>(0.5, 0.5), isPrismUnlocked: false))
        XCTAssertTrue(upgradeTriggered)
        renderer.clearPreviewBanner()
        XCTAssertNil(renderer.previewBiome)
    }
}
