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

        // Clean stale PNGs before fresh capture
        if let existing = try? FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil) {
            for item in existing where item.pathExtension.lowercased() == "png" {
                try? FileManager.default.removeItem(at: item)
            }
        }

        // 1. Sunlit Courtyard (converged with arches + reflective water basin)
        Thread.sleep(forTimeInterval: 2.6)
        try captureAndSave(name: "01_sunlit_courtyard.png", dir: outDir)

        // 2. Destructible Voxels + Creative Neon Sculpting + Sunset lighting
        let blastSlider = app.sliders["hud.slider.blastRadius"]
        if blastSlider.waitForExistence(timeout: 4.0) {
            blastSlider.adjust(toNormalizedSliderPosition: 0.76)
        }
        let sunsetBtn = app.buttons["hud.time.sunset"]
        if sunsetBtn.waitForExistence(timeout: 4.0) {
            sunsetBtn.tap()
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.49, dy: 0.48)).tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.54, dy: 0.46)).tap()
        let neonBrush = app.buttons["hud.brush.neon"]
        if neonBrush.waitForExistence(timeout: 3.0) {
            neonBrush.tap()
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.44, dy: 0.53)).tap()
        }
        Thread.sleep(forTimeInterval: 2.4)
        try captureAndSave(name: "02_voxel_destruction.png", dir: outDir)

        // 3. Neon Cavern (blooming glowing monoliths + reflective water)
        let neonBtn = app.buttons["hud.biome.neon"]
        XCTAssertTrue(neonBtn.waitForExistence(timeout: 5.0))
        neonBtn.tap()
        Thread.sleep(forTimeInterval: 2.6)
        try captureAndSave(name: "03_neon_cavern.png", dir: outDir)

        // 4. Glass Cathedral (unobstructed nave, altar, stained-glass rose window)
        let cathedralBtn = app.buttons["hud.biome.cathedral"]
        XCTAssertTrue(cathedralBtn.waitForExistence(timeout: 5.0))
        cathedralBtn.tap()
        Thread.sleep(forTimeInterval: 2.6)
        try captureAndSave(name: "04_glass_cathedral.png", dir: outDir)

        // 5. VoxelRay Studio translucent frosted Paywall
        let proBtn = app.buttons["hud.button.pro"]
        XCTAssertTrue(proBtn.waitForExistence(timeout: 5.0))
        proBtn.tap()
        XCTAssertTrue(app.otherElements["paywall.root"].waitForExistence(timeout: 5.0))
        Thread.sleep(forTimeInterval: 0.9)
        try captureAndSave(name: "05_studio_paywall.png", dir: outDir)
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
