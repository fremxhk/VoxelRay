import XCTest

final class VoxelRayUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSandboxHUDControlsCarveAndResetInLandscape() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()

        let hudRoot = app.otherElements["hud.root"]
        XCTAssertTrue(hudRoot.waitForExistence(timeout: 12.0))
        XCTAssertTrue(app.staticTexts["hud.fps"].waitForExistence(timeout: 5.0))
        XCTAssertTrue(app.staticTexts["hud.metalfx.badge"].waitForExistence(timeout: 5.0))

        let blastSlider = app.sliders["hud.slider.blastRadius"]
        XCTAssertTrue(blastSlider.waitForExistence(timeout: 5.0))
        blastSlider.adjust(toNormalizedSliderPosition: 0.78)

        let sunSlider = app.sliders["hud.slider.sunElevation"]
        XCTAssertTrue(sunSlider.waitForExistence(timeout: 5.0))
        sunSlider.adjust(toNormalizedSliderPosition: 0.35)

        let photoButton = app.buttons["hud.button.photoMode"]
        XCTAssertTrue(photoButton.waitForExistence(timeout: 5.0))

        // Tap center of the 3D viewport to carve voxels
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        // Verify Undo becomes active and works
        let undoButton = app.buttons["hud.button.undo"]
        XCTAssertTrue(undoButton.waitForExistence(timeout: 5.0))
        XCTAssertTrue(undoButton.isEnabled)
        undoButton.tap()

        // Switch to free Gold & Neon brushes and place voxels
        let goldBrush = app.buttons["hud.brush.gold"]
        XCTAssertTrue(goldBrush.waitForExistence(timeout: 5.0))
        goldBrush.tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.52)).tap()

        let sunsetBtn = app.buttons["hud.time.sunset"]
        XCTAssertTrue(sunsetBtn.waitForExistence(timeout: 5.0))
        sunsetBtn.tap()

        let muteBtn = app.buttons["hud.button.mute"]
        XCTAssertTrue(muteBtn.waitForExistence(timeout: 5.0))
        muteBtn.tap()
        muteBtn.tap()

        // Tap Reset World
        let resetButton = app.buttons["hud.button.reset"]
        XCTAssertTrue(resetButton.waitForExistence(timeout: 5.0))
        resetButton.tap()

        XCTAssertTrue(hudRoot.exists)
        XCTAssertTrue(app.staticTexts["hud.fps"].exists)
    }

    func testPhysicalDeviceWalkthrough() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-screenshots"]
        app.launch()

        let hudRoot = app.otherElements["hud.root"]
        XCTAssertTrue(hudRoot.waitForExistence(timeout: 12.0))

        // 1. Showcase Sunlit Courtyard cleanly in real time
        Thread.sleep(forTimeInterval: 2.0)

        // 2. Blast craters across central obelisk and pillars (shows 3D debris + flash + combo)
        app.buttons["hud.brush.carve"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.48)).tap()
        Thread.sleep(forTimeInterval: 0.7)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.44)).tap()
        Thread.sleep(forTimeInterval: 0.7)

        // 3. Sculpt Neon & Gold accents and shift lighting to Sunset
        app.buttons["hud.brush.neon"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.52)).tap()
        Thread.sleep(forTimeInterval: 0.7)
        app.buttons["hud.time.sunset"].tap()
        Thread.sleep(forTimeInterval: 1.5)

        // 4. Switch to Neon Cavern and carve glowing monolith
        app.buttons["hud.biome.neon"].tap()
        Thread.sleep(forTimeInterval: 2.0)
        app.buttons["hud.brush.carve"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.48)).tap()
        Thread.sleep(forTimeInterval: 1.5)

        // 5. Switch to Glass Cathedral (showingstained-glass rose window + water)
        app.buttons["hud.biome.cathedral"].tap()
        Thread.sleep(forTimeInterval: 2.4)

        // 6. Open VoxelRay Studio translucent paywall
        app.buttons["hud.button.pro"].tap()
        XCTAssertTrue(app.otherElements["paywall.root"].waitForExistence(timeout: 5.0))
        Thread.sleep(forTimeInterval: 1.8)
    }
}
