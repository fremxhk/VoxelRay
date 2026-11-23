import XCTest

final class VoxelRayUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchAndHUDVisibleInLandscape() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()

        let hudRoot = app.otherElements["hud.root"]
        XCTAssertTrue(hudRoot.waitForExistence(timeout: 10.0))
        XCTAssertTrue(app.staticTexts["hud.fps"].waitForExistence(timeout: 5.0))
        XCTAssertTrue(app.staticTexts["hud.metalfx.badge"].waitForExistence(timeout: 5.0))
    }
}
