import XCTest
import simd
@testable import VoxelRay

final class CameraTests: XCTestCase {
    func testRayDirectionNormalizedAcrossFrustum() {
        let camera = Camera(position: SIMD3<Float>(32, 16, 56), yaw: 0.35, pitch: -0.25, fovY: Float.pi / 3.0, aspect: 16.0 / 9.0)
        let samples: [SIMD2<Float>] = [
            SIMD2<Float>(0.0, 0.0),
            SIMD2<Float>(1.0, 0.0),
            SIMD2<Float>(0.0, 1.0),
            SIMD2<Float>(1.0, 1.0),
            SIMD2<Float>(0.5, 0.5),
            SIMD2<Float>(0.25, 0.75),
        ]
        for pt in samples {
            let dir = camera.rayDirection(normalizedScreenPoint: pt)
            XCTAssertFalse(dir.x.isNaN || dir.y.isNaN || dir.z.isNaN)
            XCTAssertEqual(simd_length(dir), 1.0, accuracy: 1e-5)
        }
    }

    func testCenterScreenRayMatchesForward() {
        let camera = Camera(position: SIMD3<Float>(10, 12, 40), yaw: -0.5, pitch: 0.3, fovY: 1.0, aspect: 2.16)
        let center = camera.rayDirection(normalizedScreenPoint: SIMD2<Float>(0.5, 0.5))
        let diff = simd_length(center - camera.forward)
        XCTAssertLessThan(diff, 1e-5)
    }

    func testAspectRatioScalesHorizontalSpread() {
        let camNarrow = Camera(yaw: 0, pitch: 0, fovY: Float.pi / 3.0, aspect: 1.0)
        let camWide = Camera(yaw: 0, pitch: 0, fovY: Float.pi / 3.0, aspect: 2.0)

        let rayNarrow = camNarrow.rayDirection(normalizedScreenPoint: SIMD2<Float>(1.0, 0.5))
        let rayWide = camWide.rayDirection(normalizedScreenPoint: SIMD2<Float>(1.0, 0.5))

        XCTAssertGreaterThan(rayWide.x, rayNarrow.x)
    }

    func testPitchIsClampedToSafeBounds() {
        let camera = Camera()
        camera.applyLookDelta(dx: 0, dy: -100_000, sensitivity: 0.01)
        XCTAssertEqual(camera.pitch, Camera.maxPitch, accuracy: 1e-5)

        camera.applyLookDelta(dx: 0, dy: 100_000, sensitivity: 0.01)
        XCTAssertEqual(camera.pitch, Camera.minPitch, accuracy: 1e-5)
    }

    func testCameraMutationsResetFrameIndex() {
        let camera = Camera()
        for _ in 0..<12 {
            camera.advanceFrame()
        }
        XCTAssertEqual(camera.frameIndex, 12)

        camera.applyMoveInput(forward: 1.0, strafe: 0.0, dt: 0.016)
        XCTAssertEqual(camera.frameIndex, 0)

        for _ in 0..<5 {
            camera.advanceFrame()
        }
        XCTAssertEqual(camera.frameIndex, 5)

        camera.applyLookDelta(dx: 12.0, dy: -4.0)
        XCTAssertEqual(camera.frameIndex, 0)
    }
}
