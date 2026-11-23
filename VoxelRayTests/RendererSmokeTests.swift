import XCTest
@testable import VoxelRay

final class RendererSmokeTests: XCTestCase {
    func testFrameUniformsStrideIs256Bytes() {
        XCTAssertEqual(MemoryLayout<FrameUniforms>.stride, 256)
        XCTAssertEqual(MemoryLayout<FrameUniforms>.size, 256)
    }

    private func inspectImageStats(_ pixels: [UInt8], width: Int, height: Int) -> (meanRGB: SIMD3<Double>, meanLum: Double, stddevLum: Double) {
        XCTAssertEqual(pixels.count, width * height * 4)
        var sumRGB = SIMD3<Double>(0, 0, 0)
        var lums = [Double]()
        lums.reserveCapacity(width * height)

        for idx in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[idx]) / 255.0
            let g = Double(pixels[idx + 1]) / 255.0
            let b = Double(pixels[idx + 2]) / 255.0
            let a = pixels[idx + 3]

            XCTAssertFalse(r.isNaN || g.isNaN || b.isNaN)
            XCTAssertFalse(r.isInfinite || g.isInfinite || b.isInfinite)
            XCTAssertEqual(a, 255)

            sumRGB += SIMD3<Double>(r, g, b)
            lums.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
        }

        let n = Double(lums.count)
        let meanLum = lums.reduce(0, +) / n
        let variance = lums.reduce(0) { acc, v in
            let d = v - meanLum
            return acc + d * d
        } / n
        return (sumRGB / n, meanLum, sqrt(variance))
    }

    func testOffscreenSmokeRenderProducesValidNonBlackVariance() throws {
        guard let renderer = Renderer() else {
            XCTFail("Metal Renderer failed to initialize")
            return
        }

        let width = 320
        let height = 180
        let pixels = renderer.renderOffscreen(width: width, height: height, samples: 1, smokeOnly: true)
        let stats = inspectImageStats(pixels, width: width, height: height)

        XCTAssertGreaterThan(stats.meanLum, 0.1)
        XCTAssertGreaterThan(stats.stddevLum, 0.03)
    }

    func testAllThreeBiomesProduceDistinctColorDistributions() throws {
        guard let renderer = Renderer() else {
            XCTFail("Metal Renderer failed to initialize")
            return
        }

        let width = 320
        let height = 180
        var biomeMeans = [VoxelBiome: SIMD3<Double>]()

        for biome in VoxelBiome.allCases {
            let pixels = renderer.renderOffscreen(width: width, height: height, samples: 4, biome: biome)
            let stats = inspectImageStats(pixels, width: width, height: height)
            XCTAssertGreaterThan(stats.meanLum, 0.05, "Biome \(biome) rendered too dark")
            XCTAssertGreaterThan(stats.stddevLum, 0.03, "Biome \(biome) lacked visual contrast")
            biomeMeans[biome] = stats.meanRGB
        }

        let c = biomeMeans[.sunlitCourtyard]!
        let n = biomeMeans[.neonCavern]!
        let g = biomeMeans[.glassCathedral]!

        let distCN = abs(c.x - n.x) + abs(c.y - n.y) + abs(c.z - n.z)
        let distCG = abs(c.x - g.x) + abs(c.y - g.y) + abs(c.z - g.z)
        let distNG = abs(n.x - g.x) + abs(n.y - g.y) + abs(n.z - g.z)

        XCTAssertGreaterThan(distCN, 0.08, "Courtyard and Neon Cavern color distributions must be distinct")
        XCTAssertGreaterThan(distCG, 0.05, "Courtyard and Glass Cathedral color distributions must be distinct")
        XCTAssertGreaterThan(distNG, 0.08, "Neon Cavern and Glass Cathedral color distributions must be distinct")
    }
}
