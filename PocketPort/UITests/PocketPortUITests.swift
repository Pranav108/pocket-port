import XCTest

final class PocketPortUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSameNamedFilesReopenAfterRelaunch() {
        let app = launchWithFixtures()

        importFixture("fixture-project-a", heading: "Project A plan", in: app)
        returnToLibrary(in: app)
        importFixture("fixture-project-b", heading: "Project B plan", in: app)
        returnToLibrary(in: app)

        app.terminate()
        app.launch()
        for (index, heading) in ["Project A plan", "Project B plan"].enumerated() {
            let row = app.descendants(matching: .any)
                .matching(identifier: "import-00000000-0000-4000-8000-00000000000\(index + 1)").firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.tap()
            XCTAssertTrue(app.staticTexts[heading].waitForExistence(timeout: 5))
            returnToLibrary(in: app)
        }
    }

    @MainActor
    func testInterruptedDownloadDoesNotShowSavedOrAddARow() {
        let app = launchWithFixtures()
        app.buttons["scan"].tap()
        app.buttons["fixture-interrupted"].tap()

        XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Saved offline"].exists)
        app.buttons["Cancel"].tap()
        XCTAssertFalse(app.staticTexts["PLAN.md"].exists)
    }

    @MainActor
    func testScanShowsWiFiPopoverWithoutOpeningCamera() {
        let app = launchWithFixtures(wifiConnected: false)
        app.buttons["scan"].tap()

        let message = app.descendants(matching: .any).matching(identifier: "wifi-required").firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["fixture-project-a"].exists)
        app.buttons["OK"].tap()
        XCTAssertFalse(message.exists)
    }

    @MainActor
    private func launchWithFixtures(wifiConnected: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--pocketport-ui-test", UUID().uuidString]
        if !wifiConnected { app.launchArguments.append("--pocketport-ui-test-no-wifi") }
        app.launch()
        XCTAssertTrue(app.buttons["scan"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    private func importFixture(_ identifier: String, heading: String, in app: XCUIApplication) {
        app.buttons["scan"].tap()
        app.buttons[identifier].tap()
        XCTAssertTrue(app.staticTexts[heading].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Saved offline"].exists)
    }

    @MainActor
    private func returnToLibrary(in app: XCUIApplication) {
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["scan"].waitForExistence(timeout: 5))
    }
}
