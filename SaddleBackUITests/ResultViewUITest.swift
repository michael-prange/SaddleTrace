import XCTest

/// Drives the full flow to `ResultView` and captures a screenshot, verifying the
/// visualization actually renders (Canvas + Charts) rather than only compiling.
final class ResultViewUITest: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testRendersResultView() throws {
        let app = XCUIApplication()
        app.launch()

        // Switch units to Imperial via Settings (verifies the units feature).
        app.buttons["Settings"].tap()
        let imperial = app.buttons["Imperial (in)"]
        XCTAssertTrue(imperial.waitForExistence(timeout: 5))
        imperial.tap()
        app.buttons["Done"].tap()

        // Add an animal.
        app.buttons["Add Animal"].tap()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Comanche")
        app.buttons["Save"].tap()

        // Open the animal.
        let row = app.staticTexts["Comanche"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        // Create a scan: instructions popup → capture screen. On the simulator
        // (no LiDAR) the capture screen offers a demo scan.
        app.buttons["New Scan"].tap()
        let startScan = app.buttons["Start Scan"]
        XCTAssertTrue(startScan.waitForExistence(timeout: 5), "instructions popup missing")
        startScan.tap()

        let demoScan = app.buttons["Use Demo Scan"]
        XCTAssertTrue(demoScan.waitForExistence(timeout: 10), "capture screen / demo fallback missing")
        demoScan.tap()

        let scanCell = app.cells.element(boundBy: 0)
        XCTAssertTrue(scanCell.waitForExistence(timeout: 5))
        scanCell.tap()

        // Process the demo mesh.
        let processButton = app.buttons["Process Demo Mesh"]
        XCTAssertTrue(processButton.waitForExistence(timeout: 5))
        processButton.tap()

        // ResultView should appear, including the reliability summary.
        let rocker = app.staticTexts["Topline (rocker)"]
        XCTAssertTrue(rocker.waitForExistence(timeout: 30), "ResultView did not render")
        XCTAssertTrue(app.staticTexts["Reliable stations"].exists, "reliability summary missing")

        // Capture the rendered result.
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "ResultView"
        shot.lifetime = .keepAlways
        add(shot)

        // Scroll down and grab the charts too.
        app.swipeUp()
        app.swipeUp()
        let shot2 = XCTAttachment(screenshot: app.screenshot())
        shot2.name = "ResultView-Charts"
        shot2.lifetime = .keepAlways
        add(shot2)
    }
}
