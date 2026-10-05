// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import UIKit

@MainActor final class CaptureTests: XCTestCase {
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testSyntheticStates() throws {
        try captureFixtures(["preparing", "downloading", "checking", "finishing", "paused", "foreground",
                             "stale", "failed", "completed", "long-title", "large-text"], systemAccessibility: false)
    }
    func testSystemAccessibilityStates() throws {
        try captureFixtures(["downloading", "foreground", "long-title", "large-text", "failed"],
                            systemAccessibility: true)
    }
    private func captureFixtures(_ fixtures: [String], systemAccessibility: Bool) throws {
        continueAfterFailure = false
        executionTimeAllowance = 480
        let app = XCUIApplication()
        app.launch()
        let readinessDeadline = ProcessInfo.processInfo.systemUptime + 90
        XCTAssertTrue(app.staticTexts["componentsReady"].waitForExistence(timeout: 90), app.debugDescription)
        let prefix = systemAccessibility ? "system-ax-" : ""
        capture("\(prefix)startup-components-app-synthetic-controls")
        let activityReady = app.staticTexts["activityReady"].waitForExistence(
            timeout: max(0, readinessDeadline - ProcessInfo.processInfo.systemUptime))
        if !activityReady { capture("\(prefix)startup-activity-failed-app-synthetic-controls") }
        XCTAssertTrue(activityReady, app.debugDescription)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        var observations: [[String: Any]] = []
        for fixture in fixtures {
            app.activate()
            let button = app.buttons["state.\(fixture)"]
            for _ in 0..<(systemAccessibility ? 6 : 2) { if !button.isHittable { app.swipeUp() } }
            XCTAssertTrue(button.waitForExistence(timeout: 10), fixture)
            button.tap()
            let selected = app.staticTexts["selectedFixture"]
            XCTAssertTrue(selected.waitForExistence(timeout: 5))
            let selectedMatches = NSPredicate(format: "label == %@", fixture)
            expectation(for: selectedMatches, evaluatedWith: selected)
            waitForExpectations(timeout: 10)
            app.swipeDown()
            capture("\(prefix)\(fixture)-app-synthetic-controls")
            let status = app.staticTexts["activityStatus"].value as? String ?? "unavailable"
            if systemAccessibility {
                let data = try XCTUnwrap(status.data(using: .utf8))
                let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                XCTAssertEqual(actual["systemContentSizeCategory"] as? String,
                               UIContentSizeCategory.accessibilityExtraLarge.rawValue, status)
            }
            if fixture == "downloading" {
                let data = try XCTUnwrap(status.data(using: .utf8))
                let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                XCTAssertEqual(actual["requestAccepted"] as? Bool, true, status)
                XCTAssertEqual(actual["hasArtwork"] as? Bool, true, status)
                let count = try XCTUnwrap(actual["encodedPayloadBytes"] as? Int)
                XCTAssertTrue(count > 0 && count <= 3_072, status)
            }
            XCUIDevice.shared.press(.home)
            sleep(fixture == "stale" ? 35 : 3)
            capture("\(prefix)\(fixture)-home-compact-attempt")
            let activityLabel = springboard.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS[c] %@", "Synthetic Expedition")).firstMatch
            let homeVisible = activityLabel.exists
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.035)).press(forDuration: 1.5)
            sleep(2)
            capture("\(prefix)\(fixture)-island-expanded-attempt")
            let expandedVisible = activityLabel.exists
            XCUIDevice.shared.press(.home)
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.001))
                .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.8)))
            sleep(2)
            capture("\(prefix)\(fixture)-notification-center-lock-style-attempt")
            observations.append(["fixture": fixture, "appActivityStatusBeforeBackground": status,
                "homeAccessibilityLabelFound": homeVisible, "expandedAccessibilityLabelFound": expandedVisible,
                "notificationCenterAccessibilityLabelFound": activityLabel.exists,
                "evidence": "actual simulator screenshots; requested surface and visibility probe; inspect pixels",
                "lockedDeviceAuthenticationTested": false, "systemDynamicTypeChanged": systemAccessibility])
            XCUIDevice.shared.press(.home)
        }
        if !systemAccessibility {
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
        }
        let data = try JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys])
        let record = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        record.name = "\(prefix)system-observations.json"; record.lifetime = .keepAlways; add(record)
    }
}
