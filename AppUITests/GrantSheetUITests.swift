import XCTest

/// The question sheet's choice of how long a yes is for, and the list of
/// what the agent may do without asking, in the real app on the
/// showcase's sample scenes. Nothing here touches the person's own data.
@MainActor
final class GrantSheetUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(_ scene: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-showcaseScreen", scene, "-showcaseStill", "YES"]
        app.launch()
        return app
    }

    /// Every scope shows in plain words, Just this once is chosen to start,
    /// and choosing another says what it allows.
    func testTheSheetOffersHowLongTheYesIsForAndStartsOnJustThisOnce() throws {
        let app = launch("confirmScopes")
        let once = app.buttons["grantChoice.justThisOnce"]
        XCTAssertTrue(once.waitForExistence(timeout: 15))
        XCTAssertTrue(once.isSelected)
        XCTAssertTrue(once.label.contains("Just this once"), once.label)
        let words = ["grantChoice.forThisTask": "For this task", "grantChoice.untilTonight": "Until tonight",
                     "grantChoice.always": "Always for Sam"]
        for (id, title) in words {
            let choice = app.buttons[id]
            XCTAssertTrue(choice.exists, id)
            XCTAssertFalse(choice.isSelected, id)
            XCTAssertTrue(choice.label.contains(title), choice.label)
        }
        let always = app.buttons["grantChoice.always"]
        always.tap()
        XCTAssertTrue(always.isSelected)
        XCTAssertFalse(once.isSelected)
        let promise = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@",
                                                             "without asking each time, until you remove it")).firstMatch
        XCTAssertTrue(promise.exists)
        XCTAssertTrue(app.buttons["Yes, go ahead"].exists)
    }

    /// Each grant shows who, where and for how long, and Remove takes it
    /// off the list at once.
    func testTheListShowsEachGrantAndRemoveTakesItAway() throws {
        let app = launch("memoryGrants")
        let rows = app.descendants(matching: .any).matching(identifier: "grantRow")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["What I'm allowed to do"].exists)
        XCTAssertEqual(rows.count, 3)
        let remove = app.buttons["Remove send messages to Sam"]
        XCTAssertTrue(remove.exists)
        remove.tap()
        XCTAssertTrue(remove.waitForNonExistence(timeout: 5))
        XCTAssertEqual(rows.count, 2)
    }

    /// With notes that couldn't be opened, the screen in their place still
    /// lists each grant, and Remove there takes it off the list at once.
    func testWithNoNotesTheListStillShowsAndRemoveTakesItAway() throws {
        let app = launch("memoryUnavailableGrants")
        let rows = app.descendants(matching: .any).matching(identifier: "grantRow")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["What I'm allowed to do"].exists)
        XCTAssertEqual(rows.count, 3)
        let remove = app.buttons["Remove send messages to Sam"]
        XCTAssertTrue(remove.exists)
        remove.tap()
        XCTAssertTrue(remove.waitForNonExistence(timeout: 5))
        XCTAssertEqual(rows.count, 2)
    }
}
