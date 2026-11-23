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
        XCTAssertTrue(hudRoot.waitForExistence(timeout: 10.0))
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
        let centerCoord = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        centerCoord.tap()

        // Tap Reset World
        let resetButton = app.buttons["hud.button.reset"]
        XCTAssertTrue(resetButton.waitForExistence(timeout: 5.0))
        resetButton.tap()

        XCTAssertTrue(hudRoot.exists)
        XCTAssertTrue(app.staticTexts["hud.fps"].exists)
    }
}
