import XCTest

/// The weekly digest in the real app, not the showcase: the real task
/// engine, the real notes and the real question sheet. Launch arguments
/// skip the first run; everything else is what the app itself saves in
/// the Simulator. Screenshots of Today and the question are kept with the
/// results.
@MainActor
final class DigestUITests: XCTestCase {
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func keep(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func openMemory(_ app: XCUIApplication) {
        let memory = app.buttons["What I remember"].firstMatch
        XCTAssertTrue(memory.waitForExistence(timeout: 10))
        memory.tap()
    }

    private func closeMemory(_ app: XCUIApplication) {
        if isPad {
            app.buttons["Today"].firstMatch.tap()
        } else {
            app.buttons["Done"].firstMatch.tap()
        }
    }

    /// Starts from nothing, with two notes written this week.
    private func freshNotes(_ app: XCUIApplication) {
        openMemory(app)
        let forget = app.buttons["Forget everything"].firstMatch
        if forget.waitForExistence(timeout: 3) {
            for _ in 0..<6 where !forget.isHittable { app.swipeUp() }
            let row = forget.frame
            forget.tap()
            // The dialog's own button: the one with this name that isn't the row.
            let named = app.buttons.matching(identifier: "Forget everything")
            let appeared = expectation(for: NSPredicate(format: "count > 1"), evaluatedWith: named)
            wait(for: [appeared], timeout: 5)
            let confirm = named.allElementsBoundByIndex.first { $0.frame != row && $0.isHittable }
            XCTAssertNotNil(confirm)
            confirm?.tap()
            XCTAssertTrue(app.staticTexts["Gone. I no longer have it."].waitForExistence(timeout: 5))
        }
        let field = app.textFields["Something for me to remember"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        for note in ["Dentist on Thursday at 3", "Sam's birthday is May 14. Loves lemon cake."] {
            field.tap()
            field.typeText(note)
            app.buttons["Remember"].firstMatch.tap()
            XCTAssertTrue(app.staticTexts[note].waitForExistence(timeout: 5))
        }
        closeMemory(app)
    }

    /// The digest runs on Today, asks before it keeps anything, and Not now
    /// keeps nothing. A second run with a yes keeps exactly the digest.
    func testTheDigestAsksFirstAndKeepsNothingWithoutAYes() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-pebble.onboarding.finished", "YES", "-pebble.agent.displayName", "Pip"]
        app.launch()
        freshNotes(app)

        let offer = app.buttons["Tidy my notes into a short weekly digest"].firstMatch
        XCTAssertTrue(offer.waitForExistence(timeout: 10))
        offer.tap()
        let approve = app.buttons["Check and approve"].firstMatch
        XCTAssertTrue(approve.waitForExistence(timeout: 15))
        keep("today-digest", app)

        approve.tap()
        XCTAssertTrue(app.staticTexts["Keep this in What I remember?"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["This is an example. Nothing here was really done."].exists)
        keep("ask-first", app)

        app.buttons["Not now"].firstMatch.tap()
        let closed = app.staticTexts["You closed the question, so I didn't keep the digest in your notes."].firstMatch
        XCTAssertTrue(closed.waitForExistence(timeout: 5))
        openMemory(app)
        let digest = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "This week in your notes"))
        XCTAssertTrue(app.staticTexts["Dentist on Thursday at 3"].waitForExistence(timeout: 5))
        XCTAssertEqual(digest.count, 0, "nothing is kept without a yes")
        closeMemory(app)

        // Again, with a yes this time.
        XCTAssertTrue(offer.waitForExistence(timeout: 5))
        offer.tap()
        XCTAssertTrue(approve.waitForExistence(timeout: 15))
        approve.tap()
        let yes = app.buttons["Yes, go ahead"].firstMatch
        XCTAssertTrue(yes.waitForExistence(timeout: 5))
        yes.tap()
        XCTAssertTrue(app.staticTexts["Your weekly digest is in your notes."].firstMatch.waitForExistence(timeout: 5))
        openMemory(app)
        XCTAssertTrue(digest.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(digest.count, 1)
        closeMemory(app)
    }
}
