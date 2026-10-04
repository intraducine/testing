// SPDX-License-Identifier: AGPL-3.0-only
import XCTest

@MainActor final class CaptureTests: XCTestCase {
    private func capture(_ name: String, screen: XCUIScreen = .main) {
        let attachment = XCTAttachment(screenshot: screen.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testSyntheticStates() throws {
        continueAfterFailure = false
        executionTimeAllowance = 480
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["componentsReady"].waitForExistence(timeout: 90), app.debugDescription)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        var observations: [[String: Any]] = []
        for fixture in ["preparing", "downloading", "checking", "finishing", "paused", "foreground",
                        "stale", "failed", "completed", "long-title", "large-text"] {
            app.activate()
            let button = app.buttons["state.\(fixture)"]
            for _ in 0..<2 { if !button.isHittable { app.swipeUp() } }
            XCTAssertTrue(button.waitForExistence(timeout: 10), fixture)
            button.tap()
            let selected = app.staticTexts["selectedFixture"]
            XCTAssertTrue(selected.waitForExistence(timeout: 5))
            let selectedMatches = NSPredicate(format: "label == %@", fixture)
            expectation(for: selectedMatches, evaluatedWith: selected)
            waitForExpectations(timeout: 10)
            app.swipeDown()
            capture("\(fixture)-app-synthetic-controls")
            let status = app.staticTexts["activityStatus"].value as? String ?? "unavailable"
            XCUIDevice.shared.press(.home)
            sleep(fixture == "stale" ? 35 : 3)
            capture("\(fixture)-home-compact-attempt")
            let activityLabel = springboard.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS[c] %@", "Synthetic Expedition")).firstMatch
            let homeVisible = activityLabel.exists
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.035)).press(forDuration: 1.5)
            sleep(2)
            capture("\(fixture)-island-expanded-attempt")
            let expandedVisible = activityLabel.exists
            XCUIDevice.shared.press(.home)
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.001))
                .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.8)))
            sleep(2)
            capture("\(fixture)-notification-center-lock-style-attempt")
            observations.append(["fixture": fixture, "appActivityStatusBeforeBackground": status,
                "homeAccessibilityLabelFound": homeVisible, "expandedAccessibilityLabelFound": expandedVisible,
                "notificationCenterAccessibilityLabelFound": activityLabel.exists,
                "evidence": "actual simulator screenshots; requested surface and visibility probe; inspect pixels",
                "lockedDeviceAuthenticationTested": false, "systemDynamicTypeChanged": false])
            XCUIDevice.shared.press(.home)
        }
        app.activate()
        let download = app.buttons["state.downloading"]
        for _ in 0..<2 { if !download.isHittable { app.swipeUp() } }
        download.tap()
        let cancel = app.buttons["cancelFixture"]
        if !cancel.isHittable { app.swipeUp() }
        cancel.tap()
        XCTAssertTrue(app.staticTexts["selectedFixture"].waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "label == 'cancelled'"), evaluatedWith: app.staticTexts["selectedFixture"])
        waitForExpectations(timeout: 10)
        capture("cancelled-app-synthetic-controls")
        let data = try JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys])
        let record = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        record.name = "system-observations.json"; record.lifetime = .keepAlways; add(record)
    }
}
