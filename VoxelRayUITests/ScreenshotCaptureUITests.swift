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

    /// App Review Guideline 2.1 recording: real customer launch (no test overrides)
    /// showcasing destruction, sculpting, paid biomes/StoreKit 2 paywall, and Photo Mode on iPhone.
    func testAppReviewPhysicalDeviceRecording() throws {
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2.0)

        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launch()

        let hudRoot = app.otherElements["hud.root"]
        XCTAssertTrue(hudRoot.waitForExistence(timeout: 15.0))
        Thread.sleep(forTimeInterval: 2.2)

        // Core Free Sandbox: tap-to-carve voxel destruction in Sunlit Courtyard
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.48)).tap()
        Thread.sleep(forTimeInterval: 1.0)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.44, dy: 0.46)).tap()
        Thread.sleep(forTimeInterval: 1.2)

        // Undo last blast
        let undoButton = app.buttons["hud.button.undo"]
        if undoButton.waitForExistence(timeout: 3.0), undoButton.isEnabled {
            undoButton.tap()
            Thread.sleep(forTimeInterval: 1.1)
        }

        // Creative sculpting with free Gold & Neon brushes
        let goldBrush = app.buttons["hud.brush.gold"]
        if goldBrush.waitForExistence(timeout: 3.0) {
            goldBrush.tap()
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.50)).tap()
            Thread.sleep(forTimeInterval: 0.8)
        }
        let neonBrush = app.buttons["hud.brush.neon"]
        if neonBrush.waitForExistence(timeout: 3.0) {
            neonBrush.tap()
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.53, dy: 0.49)).tap()
            Thread.sleep(forTimeInterval: 1.2)
        }

        // Time-of-day atmospheric presets
        if app.buttons["hud.time.sunset"].waitForExistence(timeout: 3.0) {
            app.buttons["hud.time.sunset"].tap()
            Thread.sleep(forTimeInterval: 1.6)
        }
        if app.buttons["hud.time.night"].waitForExistence(timeout: 3.0) {
            app.buttons["hud.time.night"].tap()
            Thread.sleep(forTimeInterval: 1.6)
        }
        if app.buttons["hud.time.noon"].waitForExistence(timeout: 3.0) {
            app.buttons["hud.time.noon"].tap()
            Thread.sleep(forTimeInterval: 1.1)
        }

        // Camera pan drag & virtual joystick flight
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.58, dy: 0.50))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.44, dy: 0.46)))
        Thread.sleep(forTimeInterval: 0.8)

        let joystick = app.descendants(matching: .any)["hud.joystick"].firstMatch
        if joystick.waitForExistence(timeout: 3.0) {
            let start = joystick.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -26)))
            Thread.sleep(forTimeInterval: 0.8)
        }

        // Paid content flow: timed Neon Cavern live preview -> VoxelRay Studio StoreKit 2 paywall
        let neonBiome = app.buttons["hud.biome.neon"]
        XCTAssertTrue(neonBiome.waitForExistence(timeout: 5.0))
        neonBiome.tap()
        Thread.sleep(forTimeInterval: 2.5)

        let previewUnlock = app.buttons["hud.preview.unlock"]
        if previewUnlock.exists && previewUnlock.isHittable {
            previewUnlock.tap()
        } else {
            let proFallback = app.buttons["hud.button.pro"]
            XCTAssertTrue(proFallback.waitForExistence(timeout: 4.0))
            proFallback.tap()
        }

        XCTAssertTrue(app.otherElements["paywall.root"].waitForExistence(timeout: 5.0))
        Thread.sleep(forTimeInterval: 2.8)

        let restoreBtn = app.buttons["paywall.restore"]
        if restoreBtn.waitForExistence(timeout: 4.0) {
            restoreBtn.tap()
            Thread.sleep(forTimeInterval: 2.2)
        }

        let paywallClose = app.buttons["paywall.close"]
        XCTAssertTrue(paywallClose.waitForExistence(timeout: 4.0))
        paywallClose.tap()
        Thread.sleep(forTimeInterval: 0.8)

        // Showcase Glass Cathedral live preview then return to Sunlit Courtyard
        let cathedralBiome = app.buttons["hud.biome.cathedral"]
        if cathedralBiome.waitForExistence(timeout: 4.0) {
            cathedralBiome.tap()
            Thread.sleep(forTimeInterval: 2.5)
        }
        let courtyardBiome = app.buttons["hud.biome.courtyard"]
        if courtyardBiome.waitForExistence(timeout: 4.0) {
            courtyardBiome.tap()
            Thread.sleep(forTimeInterval: 1.0)
        }

        // Photo Mode at end: 64-sample convergence -> native iOS Share Sheet
        let photoButton = app.buttons["hud.button.photoMode"]
        if photoButton.waitForExistence(timeout: 4.0) {
            photoButton.tap()
            let deadline = Date().addingTimeInterval(30.0)
            while Date() < deadline {
                if app.staticTexts["Photo Ready"].exists || app.otherElements["ActivityListView"].exists {
                    break
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
            Thread.sleep(forTimeInterval: 2.5)

            if app.otherElements["ActivityListView"].exists {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)))
                Thread.sleep(forTimeInterval: 0.8)
            }
            if app.otherElements["ActivityListView"].exists {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.10, dy: 0.50)).tap()
                Thread.sleep(forTimeInterval: 0.6)
            }
            let photoClose = app.buttons["hud.photo.close"]
            if photoClose.exists && photoClose.isHittable {
                photoClose.tap()
            }
            Thread.sleep(forTimeInterval: 1.0)
        }

        XCTAssertTrue(hudRoot.exists)
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
