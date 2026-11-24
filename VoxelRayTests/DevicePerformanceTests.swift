import XCTest
import QuartzCore
import simd
@testable import VoxelRay

final class DevicePerformanceTests: XCTestCase {
    func testThermalScaleBoundsAndMemoryUnderBudget() throws {
        guard let renderer = Renderer() else {
            XCTFail("Renderer unavailable")
            return
        }

        // Verify thermal scaling bounds (50% - 67% on device; 100% on Simulator)
        #if !targetEnvironment(simulator)
        XCTAssertTrue(renderer.isMetalFXActiveOnDevice, "Expected MetalFX temporal scaler support on iOS hardware")
        XCTAssertGreaterThanOrEqual(renderer.activeScaleFactor, 0.50)
        XCTAssertLessThanOrEqual(renderer.activeScaleFactor, 0.67)
        for state in [ProcessInfo.ThermalState.nominal, .fair, .serious, .critical] {
            let cfg = Metal4DevicePipeline.thermalConfig(for: state)
            XCTAssertGreaterThanOrEqual(cfg.scale, 0.50)
            XCTAssertLessThanOrEqual(cfg.scale, 0.67)
        }
        #endif

        // Exercise sustained workload across all 3 biomes + sculpting + thermal-scaled MetalFX render
        let targetWidth = 1170
        let targetHeight = 540
        let testScale: Float = renderer.isMetalFXActiveOnDevice ? renderer.activeScaleFactor : 1.0

        var peakBytes = Renderer.currentPhysicalMemoryBytes()
        var totalElapsed: CFTimeInterval = 0
        var iterations = 0

        for biome in VoxelBiome.allCases {
            renderer.selectBiome(biome)
            _ = renderer.handleViewportTap(at: SIMD2<Float>(0.5, 0.5), isPrismUnlocked: true)

            let t0 = CACurrentMediaTime()
            let pixels = renderer.renderOffscreen(
                width: targetWidth,
                height: targetHeight,
                samples: 4,
                biome: nil,
                smokeOnly: false,
                internalScale: testScale
            )
            let dt = CACurrentMediaTime() - t0
            totalElapsed += dt
            iterations += 4

            XCTAssertEqual(pixels.count, targetWidth * targetHeight * 4)
            var sumLum: Double = 0
            for idx in stride(from: 0, to: pixels.count, by: 4) {
                sumLum += Double(pixels[idx]) + Double(pixels[idx + 1]) + Double(pixels[idx + 2])
            }
            XCTAssertGreaterThan(sumLum, 0, "Rendered output must be non-black for \(biome)")

            peakBytes = max(peakBytes, Renderer.currentPhysicalMemoryBytes())
        }

        let avgSampleMs = (totalElapsed / Double(max(1, iterations))) * 1000.0
        let peakMB = Double(peakBytes) / (1024.0 * 1024.0)

        print(String(
            format: "DEVICE_PERF_TELEMETRY: backend=%@ badge=\"%@\" peakMemoryMB=%.1f avgSampleMs=%.2f thermalState=%d",
            renderer.activeRenderingBackendDescription,
            renderer.thermalBadgeText,
            peakMB,
            avgSampleMs,
            ProcessInfo.processInfo.thermalState.rawValue
        ))

        // Hard ceiling: < 1.2 GB resident physical memory (critical for 4 GB RAM iPhone 13)
        XCTAssertLessThan(peakBytes, 1_200_000_000, "Peak physical footprint \(peakMB) MB exceeded 1.2 GB ceiling")
    }
}
