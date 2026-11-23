import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers

final class ScreenshotCaptureUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCaptureAppStore69InchLandscapeScreenshots() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-screenshots"]
        app.launch()

        let hudRoot = app.otherElements["hud.root"]
        XCTAssertTrue(hudRoot.waitForExistence(timeout: 12.0))

        let outDirPath = ProcessInfo.processInfo.environment["VOXELRAY_SCREENSHOT_DIR"]
            ?? "/Volumes/XCode/Vortex/artifacts/screenshots"
        let outDir = URL(fileURLWithPath: outDirPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // 1. Sunlit Courtyard (converged)
        Thread.sleep(forTimeInterval: 2.5)
        try captureAndSave(name: "01_sunlit_courtyard.png", dir: outDir)

        // 2. Destructible Voxels (carved + dramatic sun angle)
        let blastSlider = app.sliders["hud.slider.blastRadius"]
        if blastSlider.waitForExistence(timeout: 4.0) {
            blastSlider.adjust(toNormalizedSliderPosition: 0.85)
        }
        let sunSlider = app.sliders["hud.slider.sunElevation"]
        if sunSlider.waitForExistence(timeout: 4.0) {
            sunSlider.adjust(toNormalizedSliderPosition: 0.25)
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.50)).tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.54, dy: 0.47)).tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.44, dy: 0.55)).tap()
        Thread.sleep(forTimeInterval: 2.2)
        try captureAndSave(name: "02_voxel_destruction.png", dir: outDir)

        // 3. Neon Cavern (Pro biome converged)
        let neonBtn = app.buttons["hud.biome.neon"]
        XCTAssertTrue(neonBtn.waitForExistence(timeout: 5.0))
        neonBtn.tap()
        Thread.sleep(forTimeInterval: 2.5)
        try captureAndSave(name: "03_neon_cavern.png", dir: outDir)

        // 4. Glass Cathedral + Architect Pro Paywall sheet
        let cathedralBtn = app.buttons["hud.biome.cathedral"]
        XCTAssertTrue(cathedralBtn.waitForExistence(timeout: 5.0))
        cathedralBtn.tap()
        Thread.sleep(forTimeInterval: 2.0)

        let proBtn = app.buttons["hud.button.pro"]
        XCTAssertTrue(proBtn.waitForExistence(timeout: 5.0))
        proBtn.tap()
        XCTAssertTrue(app.otherElements["paywall.root"].waitForExistence(timeout: 5.0))
        Thread.sleep(forTimeInterval: 0.8)
        try captureAndSave(name: "04_glass_cathedral_paywall.png", dir: outDir)
    }

    private func captureAndSave(name: String, dir: URL) throws {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let fileURL = dir.appendingPathComponent(name)
        try saveOpaqueLandscape24BitPNG(image: shot.image, to: fileURL)
    }

    private func saveOpaqueLandscape24BitPNG(image: UIImage, to url: URL) throws {
        guard let cg = image.cgImage else {
            throw NSError(domain: "VoxelRayScreenshots", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing CGImage"])
        }

        let srcW = cg.width
        let srcH = cg.height
        let dstW = max(srcW, srcH)
        let dstH = min(srcW, srcH)

        // Render into 32-bit RGBX buffer, orienting landscape if needed, then strip to pure 24-bit RGB
        let rgbaBytesPerRow = dstW * 4
        var rgba = [UInt8](repeating: 0, count: rgbaBytesPerRow * dstH)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let ctx = CGContext(
            data: &rgba,
            width: dstW,
            height: dstH,
            bitsPerComponent: 8,
            bytesPerRow: rgbaBytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw NSError(domain: "VoxelRayScreenshots", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to build RGBX context"])
        }

        if srcW < srcH {
            // Rotate 90 degrees CW in CGContext (upright LandscapeLeft)
            ctx.translateBy(x: CGFloat(dstW), y: 0)
            ctx.rotate(by: .pi / 2.0)
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: srcW, height: srcH))
        } else {
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))
        }

        var rgb = [UInt8](repeating: 0, count: dstW * dstH * 3)
        for i in 0..<(dstW * dstH) {
            let s = i * 4
            let d = i * 3
            rgb[d] = rgba[s]
            rgb[d + 1] = rgba[s + 1]
            rgb[d + 2] = rgba[s + 2]
        }

        guard let provider = CGDataProvider(data: Data(rgb) as CFData),
              let outCG = CGImage(
                width: dstW,
                height: dstH,
                bitsPerComponent: 8,
                bitsPerPixel: 24,
                bytesPerRow: dstW * 3,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            throw NSError(domain: "VoxelRayScreenshots", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to encode 24-bit RGB PNG"])
        }

        CGImageDestinationAddImage(dest, outCG, nil)
        if !CGImageDestinationFinalize(dest) {
            throw NSError(domain: "VoxelRayScreenshots", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to finalize PNG"])
        }
    }
}
