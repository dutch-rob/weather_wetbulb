//
//  IndoorForecastUITests.swift
//  weather_wetbulbUITests
//
//  The indoor forecast's pointers are dragged and tapped, and neither can be
//  checked by a unit test: a gesture that an ancestor quietly swallows still
//  compiles, still draws, and does nothing. These drive the real screen.
//
//  The app fills the screen from a fixture when FORECAST_PREVIEW is set, since
//  a simulator has no station readings and no iCloud account to fetch them
//  with. Debug builds only.
//

import XCTest

final class IndoorForecastUITests: XCTestCase {

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["FORECAST_PREVIEW"] = "1"
        app.launch()
        return app
    }

    /// The first scenario slider, which opens on the cooler running from now.
    private func slider(_ app: XCUIApplication) -> XCUIElement {
        let row = app.otherElements["scenario1"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the indoor forecast did not appear")
        return row
    }

    private func summary(_ app: XCUIApplication) -> String {
        app.staticTexts["scenario1.summary"].label
    }

    func testTappingAPointerOpensItsMenu() {
        let app = launch()
        let row = slider(app)
        // A tap near the left-hand end, where the first pointer sits.
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["Starts at"].waitForExistence(timeout: 5),
                      "tapping a pointer did not open its menu")
        XCTAssertTrue(app.buttons["Done"].exists)
    }

    func testDraggingAPointerMovesItsEventLater() {
        let app = launch()
        let row = slider(app)
        let before = summary(app)
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5))
            .press(forDuration: 0.1,
                   thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)))
        let after = summary(app)
        XCTAssertNotEqual(before, after, "dragging the pointer did not move its event")
        XCTAssertTrue(after.contains("swamp"), "the event changed into something else: \(after)")
    }

    func testDraggingTheSecondPointerInAddsAnEvent() {
        let app = launch()
        let row = slider(app)
        XCTAssertFalse(summary(app).contains("→"), "the scenario started with two events")
        // From the parked right-hand end, inwards.
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5))
            .press(forDuration: 0.1,
                   thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)))
        XCTAssertTrue(summary(app).contains("→"),
                      "dragging the second pointer in did not add an event: \(summary(app))")
    }
}
