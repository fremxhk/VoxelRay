import XCTest
@testable import VoxelRay

final class RendererSmokeTests: XCTestCase {
    func testFrameUniformsStrideIs256Bytes() {
        XCTAssertEqual(MemoryLayout<FrameUniforms>.stride, 256)
        XCTAssertEqual(MemoryLayout<FrameUniforms>.size, 256)
    }

    func testOffscreenSmokeRenderProducesValidNonBlackVariance() throws {
        guard let renderer = Renderer() else {
            XCTFail("Metal Renderer failed to initialize")
            return
        }

        let width = 320
        let height = 180
        let pixels = renderer.renderOffscreen(width: width, height: height, samples: 1)
        XCTAssertEqual(pixels.count, width * height * 4)

        var luminances = [Double]()
        luminances.reserveCapacity(width * height)
        var nonZeroChannels = 0

        for idx in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[idx]) / 255.0
            let g = Double(pixels[idx + 1]) / 255.0
            let b = Double(pixels[idx + 2]) / 255.0
            let a = pixels[idx + 3]

            XCTAssertFalse(r.isNaN || g.isNaN || b.isNaN)
            XCTAssertFalse(r.isInfinite || g.isInfinite || b.isInfinite)
            XCTAssertEqual(a, 255)

            if r > 0.01 || g > 0.01 || b > 0.01 {
                nonZeroChannels += 1
            }
            let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
            luminances.append(lum)
        }

        XCTAssertGreaterThan(nonZeroChannels, (width * height) / 2)

        let mean = luminances.reduce(0, +) / Double(luminances.count)
        let variance = luminances.reduce(0) { acc, v in
            let d = v - mean
            return acc + d * d
        } / Double(luminances.count)
        let stddev = sqrt(variance)

        XCTAssertGreaterThan(mean, 0.1)
        XCTAssertGreaterThan(stddev, 0.03)
    }
}
