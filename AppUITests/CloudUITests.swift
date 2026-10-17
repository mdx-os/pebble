import XCTest

/// Drives the cloud screens in the real app. They come from the showcase,
/// whose transport refuses every request, so nothing is ever sent.
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
        let said = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "You said: Help me write a note to hidden name")).firstMatch
        XCTAssertTrue(said.exists)
        XCTAssertFalse(said.label.contains("["))
        app.buttons["Don't send"].tap()
        XCTAssertTrue(app.staticTexts["Here is exactly what leaves your device"].waitForNonExistence(timeout: 5))
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

    /// Turning it on asks first, and Not now leaves it off.
    func testTurningOnAsksFirst() throws {
        let app = launch("cloudAsk")
        XCTAssertTrue(app.staticTexts["Turn on help from the cloud?"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "I try to take out")).firstMatch.exists)
        app.buttons["Not now"].tap()
        XCTAssertTrue(app.staticTexts["Off. Everything I do stays on this device."].waitForExistence(timeout: 5))
    }
}
