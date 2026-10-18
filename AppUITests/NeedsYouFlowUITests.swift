import XCTest

/// Drives the Needs you flow in the real app, on the showcase's live ask
/// scene: the scripted dentist search reaches its one question as the app
/// opens. Nothing here touches the person's own data.
@MainActor
final class NeedsYouFlowUITests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    /// `keep` opens on what the last launch kept, as the app does after it
    /// was closed. `hold` makes the held visit take that long after a yes.
    private func launch(keep: Bool = false, hold: Int? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-showcaseScreen", "askLive"]
        if keep { app.launchArguments += ["-showcaseKeepAsks", "YES"] }
        if let hold { app.launchArguments += ["-showcaseHoldSeconds", String(hold)] }
        app.launch()
        return app
    }

    private func approve(in app: XCUIApplication) -> XCUIElement {
        app.buttons["Check and approve"].firstMatch
    }

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Where Today's composer starts, so a tap aims above it.
    private func composerTop(in app: XCUIApplication) -> CGFloat {
        let field = element("todayComposer", in: app)
        return field.exists ? field.frame.minY - 12 : app.frame.maxY
    }

    /// Every receipt on Today. Each is one element, its label the summary
    /// VoiceOver reads.
    private func receipts(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "receipt")
    }

    private func text(containing words: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
    }

    /// The question is pinned once, the sheet says what happens, to whom
    /// and what is shared, a yes leaves one receipt, and the receipt can be
    /// cleared. A second tap on the same yes is covered by the unit tests
    /// on `ConfirmationState` and `usedYes`: the sheet is gone after one.
    func testAYesLeavesOneReceiptThatCanBeCleared() throws {
        let app = launch()
        XCTAssertTrue(approve(in: app).waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Needs you"].exists)
        // Nothing asks the system at launch: the offer waits on Today.
        XCTAssertFalse(springboard.alerts.firstMatch.exists)
        XCTAssertTrue(element("nudgeOffer", in: app).exists)

        approve(in: app).tap()
        let yes = app.buttons["Yes, go ahead"]
        XCTAssertTrue(yes.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["What happens"].exists)
        XCTAssertTrue(app.staticTexts["I'll hold a visit for you on Saturday at 10:30."].exists)
        XCTAssertTrue(app.staticTexts["Shared"].exists)
        XCTAssertTrue(app.staticTexts["mapledental.example"].exists)
        XCTAssertTrue(app.staticTexts["Maple Dental"].exists)
        XCTAssertTrue(app.staticTexts["sampleLabel"].exists, "the scripted question says it is an example")
        yes.tap()

        // The card leaves Needs you, and the receipt arrives once the visit is held.
        let receipt = receipts(in: app).firstMatch
        XCTAssertTrue(receipt.waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["Needs you"].exists)
        XCTAssertFalse(approve(in: app).exists)
        XCTAssertEqual(receipts(in: app).count, 1)
        XCTAssertTrue(receipt.label.contains("You said yes"), receipt.label)
        XCTAssertTrue(receipt.label.contains("Done, once, just as you said yes to it."), receipt.label)

        let clear = element("clearReceipt", in: app)
        XCTAssertEqual(clear.label, "Clear your details for Maple Dental", "Clear says which receipt it clears")
        clear.tap()
        XCTAssertTrue(receipt.waitForNonExistence(timeout: 5))
    }

    /// Not now ends the question, and the card says so in plain words.
    func testNotNowEndsTheQuestionWithALineOnTheCard() throws {
        let app = launch()
        XCTAssertTrue(approve(in: app).waitForExistence(timeout: 15))
        approve(in: app).tap()
        let notNow = app.buttons["Not now"]
        XCTAssertTrue(notNow.waitForExistence(timeout: 5))
        notNow.tap()
        XCTAssertTrue(text(containing: "You closed the question, so I didn't hold a Saturday visit.", in: app)
            .waitForExistence(timeout: 5))
        XCTAssertFalse(approve(in: app).exists)
        XCTAssertFalse(receipts(in: app).firstMatch.exists, "nothing was approved, so there is no receipt")
    }

    /// Closing the app keeps the question. A yes under way when it closed
    /// is never run again: the card and the receipt say it may be done.
    func testClosingTheAppKeepsTheQuestionAndNeverReplaysAYes() throws {
        var app = launch(hold: 120)
        XCTAssertTrue(approve(in: app).waitForExistence(timeout: 15))
        app.terminate()

        app = launch(keep: true, hold: 120)
        XCTAssertTrue(approve(in: app).waitForExistence(timeout: 15), "the question is still pinned")
        approve(in: app).tap()
        let yes = app.buttons["Yes, go ahead"]
        XCTAssertTrue(yes.waitForExistence(timeout: 5))
        yes.tap()
        XCTAssertTrue(yes.waitForNonExistence(timeout: 5))
        app.terminate()

        app = launch(keep: true, hold: 120)
        XCTAssertTrue(text(containing: "I was closed before I could finish", in: app).waitForExistence(timeout: 15))
        XCTAssertTrue(text(containing: "It may be done.", in: app).exists)
        // The receipt says so too: exactly one, in its own words, not the
        // task card's.
        let receipt = receipts(in: app).firstMatch
        for _ in 0..<3 where !receipt.exists { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(receipt.waitForExistence(timeout: 5), "the restored receipt is on Today")
        XCTAssertEqual(receipts(in: app).count, 1)
        XCTAssertTrue(receipt.label.contains("You said yes"), receipt.label)
        XCTAssertTrue(receipt.label.contains("I'd started this when I stopped, so it may be done."), receipt.label)
        XCTAssertFalse(receipt.label.contains("Done, once"), receipt.label)
        XCTAssertFalse(approve(in: app).exists, "the yes is never asked for or used again")
    }

    /// The nudge is offered in the moment, the system asks only after a
    /// yes, the lock screen line names nothing, and opening it goes
    /// straight to the pinned card.
    func testANudgeIsAskedForInContextAndOpensThePinnedCard() throws {
        let app = launch()
        // The system asks only once per install. `make ui-test` removes the
        // app from each simulator first, so it hasn't yet.
        let permission = element("nudgePermission", in: app)
        XCTAssertTrue(permission.waitForExistence(timeout: 15))
        let checked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", "checking"), object: permission)
        XCTAssertEqual(XCTWaiter.wait(for: [checked], timeout: 10), .completed)
        // A simulator asked before can't show the system's question again,
        // so this fails rather than pass without meeting it.
        XCTAssertEqual(permission.label, "notDetermined",
                       "Notifications were already allowed or refused here. Run through `make ui-test`, which removes the app first.")
        XCTAssertTrue(approve(in: app).waitForExistence(timeout: 15))
        XCTAssertFalse(springboard.alerts.firstMatch.exists, "never asked at launch")
        let allow = app.buttons["Yes, nudge me"]
        XCTAssertTrue(allow.waitForExistence(timeout: 5))
        // Below the pinned card, so on a phone it may sit under the composer.
        for _ in 0..<3 where !allow.isHittable || allow.frame.maxY > composerTop(in: app) {
            app.scrollViews.firstMatch.swipeUp()
        }
        allow.tap()
        // The system's own question, only now.
        let systemAllow = springboard.alerts.buttons["Allow"]
        XCTAssertTrue(systemAllow.waitForExistence(timeout: 5))
        systemAllow.tap()
        XCTAssertTrue(element("nudgeOffer", in: app).waitForNonExistence(timeout: 5))

        // The nudge waits a little after the app goes away, so a quick
        // switch to another app sends nothing.
        XCUIDevice.shared.press(.home)
        let banner = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Pip has a question for you")).firstMatch
        XCTAssertFalse(banner.waitForExistence(timeout: 10), "not at once")
        XCTAssertTrue(banner.waitForExistence(timeout: 60))
        for held in ["Maple", "mapledental", "Saturday", "phone", "dentist"] {
            XCTAssertFalse(banner.label.localizedCaseInsensitiveContains(held), "the nudge shows \(held)")
        }
        // A banner can still be settling as it is found, so tap again if
        // the first one didn't open the app.
        for _ in 0..<3 where app.state != .runningForeground && banner.exists {
            banner.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = app.wait(for: .runningForeground, timeout: 10)
        }
        XCTAssertEqual(app.state, .runningForeground, "opening the nudge opens the app, and it stays open")
        XCTAssertTrue(approve(in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(approve(in: app).isHittable, "the pinned card is in view")
    }
}
