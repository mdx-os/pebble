import XCTest

/// Drives the cloud screens in the real app. Most come from the showcase,
/// whose transport refuses every request, so nothing is ever sent. The way
/// in from the memory screen is driven in the app as people get it.
@MainActor
final class CloudUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(_ screen: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-pebbleScreen", screen]
        app.launch()
        return app
    }

    /// The preview shows the whole request, VoiceOver reads it message by
    /// message with masks in words, and Don't send closes it.
    func testThePreviewShowsTheWholeRequestAndReadsWell() throws {
        let app = launch("cloudPreview")
        XCTAssertTrue(app.staticTexts["Here is exactly what leaves your device"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Going to https://cloud.example.com/v1/reply."].exists)
        let labels = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Sent with these labels:")).firstMatch
        XCTAssertTrue(labels.exists)
        XCTAssertTrue(labels.label.contains("User-Agent, pebble"))
        // The sign-in label is named, but its value is never spoken.
        XCTAssertTrue(labels.label.contains("X-Sample-Sign-In, sign-in value, 14 characters"))
        XCTAssertFalse(labels.label.contains("made-up-sample"))
        let said = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "You said: Help me write a note to hidden name")).firstMatch
        XCTAssertTrue(said.exists)
        XCTAssertFalse(said.label.contains("["))
        app.buttons["Don't send"].tap()
        XCTAssertTrue(app.staticTexts["Here is exactly what leaves your device"].waitForNonExistence(timeout: 5))
    }

    /// A long press on the request offers no Copy, so a sign-in value never
    /// reaches the clipboard.
    func testThePreviewTextCantBeCopied() throws {
        let app = launch("cloudPreview")
        let said = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "You said:")).firstMatch
        XCTAssertTrue(said.waitForExistence(timeout: 10))
        said.press(forDuration: 1.2)
        XCTAssertFalse(app.menuItems["Copy"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["Copy"].exists)
        XCTAssertTrue(app.staticTexts["Here is exactly what leaves your device"].exists)
    }

    /// The private word field never learns words, its add button is big
    /// enough to tap, and a word added shows in the list.
    func testAPrivateWordCanBeAddedWithABigEnoughButton() throws {
        let app = launch("cloudOff")
        let add = app.buttons["Hide this word"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(add.frame.width, 44)
        XCTAssertGreaterThanOrEqual(add.frame.height, 44)
        let field = app.textFields["A word or name to keep private"]
        field.tap()
        field.typeText("riverside clinic")
        add.tap()
        // Typed in lowercase, kept in lowercase: nothing was capitalized or corrected.
        XCTAssertTrue(app.buttons["Stop hiding riverside clinic"].waitForExistence(timeout: 5))
    }

    /// The back button of the stack `element` is in: of the bars above it,
    /// the lowest one, which is the sheet's on iPhone and the detail's on
    /// iPad, and its leftmost button.
    private func backButton(over element: XCUIElement, in app: XCUIApplication) throws -> XCUIElement {
        let midX = element.frame.midX
        let bars = app.navigationBars.allElementsBoundByIndex.filter {
            $0.frame.minX <= midX && midX <= $0.frame.maxX && $0.frame.maxY <= element.frame.minY
        }
        let bar = try XCTUnwrap(bars.max { $0.frame.minY < $1.frame.minY }, "no bar above the screen")
        let buttons = bar.buttons.allElementsBoundByIndex
        return try XCTUnwrap(buttons.min { $0.frame.minX < $1.frame.minX }, "no button in the bar")
    }

    /// The cloud setting's only way in is the row at the foot of the memory
    /// screen. Here it is tapped in the app as people get it, not the
    /// showcase: the memory as a sheet on iPhone and in the sidebar's detail
    /// on iPad, so the link must work inside each. Launch arguments skip the
    /// first run; they only fill the argument domain, so nothing is changed
    /// but what the app itself saves in the Simulator. The toggle is never
    /// touched.
    func testTheCloudRowOpensTheSettingFromTheRealMemoryScreen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-pebble.onboarding.finished", "YES", "-pebble.agent.displayName", "Pip"]
        app.launch()
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let memory = app.buttons["What I remember"].firstMatch
        XCTAssertTrue(memory.waitForExistence(timeout: 10))
        memory.tap()
        let row = app.buttons["cloudRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        // Notes saved on this Simulator earlier can push it down.
        for _ in 0..<6 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.isHittable)
        row.tap()
        let toggle = app.switches["cloudToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), isPad ? "iPad sidebar detail" : "iPhone memory sheet")
        XCTAssertTrue(app.staticTexts["Words I always hide"].exists)
        // Back to the memory screen the same way.
        // Found by where it is, not by "BackButton", which isn't the same on
        // every iOS version or in a stack shown in a sheet. The order of the
        // bars isn't either: on iPhone the home screen's bar is still there
        // under the sheet, and on iPad the sidebar has one of its own.
        try backButton(over: toggle, in: app).tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertFalse(toggle.exists)
    }

    /// Turning it on asks first, and Not now leaves it off.
    func testTurningOnAsksFirst() throws {
        let app = launch("cloudAsk")
        XCTAssertTrue(app.staticTexts["Turn on help from the cloud?"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "I try to take out")).firstMatch.exists)
        app.buttons["Not now"].tap()
        XCTAssertTrue(app.staticTexts["Off. Everything I do stays on this device."].waitForExistence(timeout: 5))
    }
}
