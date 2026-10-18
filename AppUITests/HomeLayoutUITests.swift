import XCTest

/// Drives the real app in the Simulator. Screens come from the showcase, so
/// nothing here touches the person's own data.
@MainActor
final class HomeLayoutUITests: XCTestCase {
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

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

    private func composer(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "composer").firstMatch
    }

    /// On a full screen iPad the places sit in a sidebar beside the chat,
    /// in both orientations. On a standard size iPhone the chat is alone and
    /// the memory opens over it. (Larger iPhones are regular width in
    /// landscape, so they get the sidebar there too.)
    func testTheSidebarShowsOnIPadAndNotOnIPhone() throws {
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let app = launch("home")
            XCTAssertTrue(composer(in: app).waitForExistence(timeout: 10))
            let chatRow = app.buttons["Chat"].firstMatch
            if isPad {
                XCTAssertTrue(chatRow.waitForExistence(timeout: 5), "sidebar in \(orientation.rawValue)")
                app.buttons["What I remember"].firstMatch.tap()
                XCTAssertTrue(app.staticTexts["Prefers tea in the afternoon"].waitForExistence(timeout: 5))
                chatRow.tap()
                XCTAssertTrue(composer(in: app).waitForExistence(timeout: 5))
            } else {
                XCTAssertFalse(chatRow.exists)
                app.buttons["What I remember"].firstMatch.tap()
                XCTAssertTrue(app.staticTexts["Prefers tea in the afternoon"].waitForExistence(timeout: 5))
                app.buttons["Done"].firstMatch.tap()
                XCTAssertTrue(composer(in: app).waitForExistence(timeout: 5))
            }
        }
    }

    /// Return sends, from the on-screen keyboard and a hardware one alike;
    /// both reach the field as a typed line break. XCUITest drops the Return
    /// key from typeKey with or without modifiers, so Shift Return can't be
    /// driven here; `ComposerReturnTests` covers the rule it relies on.
    func testReturnSends() throws {
        let app = launch("home")
        let field = composer(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Pack lunches")
        field.typeText("\n")
        XCTAssertTrue(app.staticTexts["Pack lunches"].waitForExistence(timeout: 5))
        // Empty again (an empty field reports its placeholder).
        XCTAssertFalse((field.value as? String ?? "").contains("Pack lunches"))
    }

    /// Today is home. On iPad it is the first place in the sidebar, chosen
    /// first; on iPhone the chat is one tap away at the bottom.
    func testTodayIsHomeAndTheChatIsOneTapAway() throws {
        let app = launch("today")
        // Examples say so first, to VoiceOver too.
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Example. Done. Your morning plan is set")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Needs you"].exists)
        if isPad {
            XCTAssertTrue(app.buttons["Today"].firstMatch.exists)
            app.buttons["Chat"].firstMatch.tap()
            XCTAssertTrue(composer(in: app).waitForExistence(timeout: 5))
            app.buttons["Today"].firstMatch.tap()
        } else {
            app.buttons["chatButton"].tap()
            XCTAssertTrue(composer(in: app).waitForExistence(timeout: 5))
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(card.waitForExistence(timeout: 5))

        // The examples say so on the first screen, above every card.
        let sampleNote = app.staticTexts["sampleNote"]
        XCTAssertTrue(sampleNote.exists)
        XCTAssertTrue(sampleNote.isHittable)
        XCTAssertLessThan(sampleNote.frame.minY, card.frame.minY)

        // A result opens to read, says it is an example, and Done closes it.
        card.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "School drop off")).firstMatch
            .waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["sampleLabel"].exists)
        app.buttons["Done"].firstMatch.tap()

        // Something spotted opens the chat with a line ready, not sent.
        let spotted = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Example. Noticed. Sam's birthday")).firstMatch
        XCTAssertTrue(spotted.waitForExistence(timeout: 5))
        spotted.tap()
        let field = composer(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Help me plan something for Sam's birthday.")
        XCTAssertFalse(app.staticTexts["Help me plan something for Sam's birthday."].exists)
    }

    /// A question waiting is pinned on top and opens the usual question
    /// sheet. Not now withdraws it, and the section goes away.
    func testNeedsYouOpensTheQuestionSheet() throws {
        let app = launch("todayNeedsYou")
        XCTAssertTrue(app.staticTexts["Needs you"].waitForExistence(timeout: 10))
        let question = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Example. Needs you. Pay")).firstMatch
        XCTAssertTrue(question.exists)
        question.tap()
        XCTAssertTrue(app.buttons["Yes, go ahead"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Checking with you first"].exists)
        // The sample payment says it is an example.
        XCTAssertTrue(app.staticTexts["sampleLabel"].exists)
        app.buttons["Not now"].tap()
        XCTAssertTrue(app.staticTexts["Needs you"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(question.exists)
    }

    /// A brand new person sees a kind empty state, no Needs you section,
    /// and the composer right there: type, Return, and the chat opens with
    /// the line sent.
    func testABrandNewPersonCanTypeAndGoFromToday() throws {
        let app = launch("todayEmpty")
        XCTAssertTrue(app.staticTexts["A quiet start"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Needs you"].exists)
        XCTAssertFalse(app.buttons["Say hello"].exists)
        let today = app.descendants(matching: .any).matching(identifier: "todayComposer").firstMatch
        XCTAssertTrue(today.exists)
        today.tap()
        today.typeText("Pack lunches")
        today.typeText("\n")
        let field = composer(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Pack lunches"].waitForExistence(timeout: 5))
        XCTAssertFalse((field.value as? String ?? "").contains("Pack lunches"))
    }

    /// Work done while the app was closed shows in Today: this morning's
    /// summary opens to read, and a morning that never ran says why. Both
    /// are examples here, and say so first.
    func testTheMorningSummaryShowsInToday() throws {
        let app = launch("todaySummary")
        let summary = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Example. Ready for you. Your morning summary")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Needs you"].exists, "the question it counted still waits")
        let missed = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Example. Noticed. I couldn't make")).firstMatch
        XCTAssertTrue(missed.exists)
        XCTAssertTrue(missed.label.contains("Low Power Mode"))
        summary.tap()
        let detail = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Anything still waiting")).firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["sampleLabel"].exists)
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
    }

    /// Background work is off until the person turns it on, and then the
    /// screen says when the next summary is due.
    func testBackgroundWorkIsOffUntilTurnedOn() throws {
        let app = launch("memory")
        let toggle = app.switches["backgroundSwitch"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        for _ in 0..<3 where !toggle.isHittable { app.swipeUp() }
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertFalse(app.staticTexts["backgroundNext"].exists)
        // The switch itself sits at the trailing end of the row.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["backgroundNext"].waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1")
    }

    /// Typing on Today and pressing Command 2 still goes to the chat, and
    /// the words come along.
    func testCommandTwoGoesToTheChatFromTodaysComposer() throws {
        try XCTSkipUnless(isPad, "hardware keyboard shortcuts are an iPad feature")
        let app = launch("todayEmpty")
        let today = app.descendants(matching: .any).matching(identifier: "todayComposer").firstMatch
        XCTAssertTrue(today.waitForExistence(timeout: 10))
        // Menu commands can take a moment to attach after launch, and a
        // press that early reaches a focused field as a typed "2". Wait for
        // them with nothing focused: Command 3 opens the memory once they
        // are there, and Command 1 comes back.
        let note = app.staticTexts["Prefers tea in the afternoon"]
        for _ in 0..<3 where !note.exists {
            app.typeKey("3", modifierFlags: .command)
            _ = note.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(note.exists)
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(today.waitForExistence(timeout: 5))
        today.tap()
        today.typeText("Half typed")
        app.typeKey("2", modifierFlags: .command)
        let field = composer(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Half typed")
        XCTAssertFalse(app.staticTexts["Half typed"].exists)
    }

    /// Command N starts a new chat; Command 1, 2 and 3 move between places
    /// in sidebar order.
    func testCommandShortcuts() throws {
        try XCTSkipUnless(isPad, "hardware keyboard shortcuts are an iPad feature")
        let app = launch("home")
        XCTAssertTrue(composer(in: app).waitForExistence(timeout: 10))
        let earlier = app.staticTexts["school drop off, gym, answer Priya, groceries"]
        XCTAssertTrue(earlier.exists)

        // Right after launch the menu commands can take a moment to attach
        // to the window, and a press that early is dropped. Try a few times.
        let note = app.staticTexts["Prefers tea in the afternoon"]
        for _ in 0..<3 where !note.exists {
            app.typeKey("3", modifierFlags: .command)
            _ = note.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(note.exists)
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["A quiet start"].waitForExistence(timeout: 5))
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(composer(in: app).waitForExistence(timeout: 5))

        // The person has spoken in this chat, so a new one asks first.
        app.typeKey("n", modifierFlags: .command)
        let keep = app.alerts.buttons["Keep this chat"]
        XCTAssertTrue(keep.waitForExistence(timeout: 5))
        keep.tap()
        XCTAssertTrue(earlier.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Plan my morning"].exists)

        app.typeKey("n", modifierFlags: .command)
        let start = app.alerts.buttons["Start new chat"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(app.buttons["Plan my morning"].waitForExistence(timeout: 5))
        XCTAssertFalse(earlier.exists)

        // An untouched chat starts over without asking.
        app.typeKey("n", modifierFlags: .command)
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Plan my morning"].exists)

        app.typeKey("/", modifierFlags: .command)
        XCTAssertTrue(app.navigationBars["Keyboard shortcuts"].waitForExistence(timeout: 5))
    }
}

/// Screenshots of each showcase screen in portrait and landscape. Runs only
/// when PEBBLE_SHOTS names a folder (pass TEST_RUNNER_PEBBLE_SHOTS to
/// xcodebuild); see scripts/device-screenshots.sh.
@MainActor
final class ShowcaseShots: XCTestCase {
    func testCaptureEachScreen() throws {
        let env = ProcessInfo.processInfo.environment
        guard let folder = env["PEBBLE_SHOTS"], !folder.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_PEBBLE_SHOTS to capture screenshots")
        }
        let device = (env["SIMULATOR_DEVICE_NAME"] ?? UIDevice.current.name)
            .lowercased()
            .filter { $0 != "(" && $0 != ")" }
            .replacingOccurrences(of: " ", with: "-")
        let out = URL(fileURLWithPath: folder).appendingPathComponent(device)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let screens = (env["PEBBLE_SCREENS"].flatMap { $0.isEmpty ? nil : $0 }
                       ?? "today todayNeedsYou todayEmpty home homeMemory shortcuts hello ideas firstChat confirm")
            .split(separator: " ").map(String.init)

        for (name, orientation) in [("portrait", UIDeviceOrientation.portrait), ("landscape", .landscapeLeft)] {
            XCUIDevice.shared.orientation = orientation
            for screen in screens {
                let app = XCUIApplication()
                app.launchArguments = ["-pebbleScreen", screen]
                app.launch()
                // Let entrances and the sidebar settle.
                Thread.sleep(forTimeInterval: 2.5)
                let png = XCUIScreen.main.screenshot().pngRepresentation
                try png.write(to: out.appendingPathComponent("\(screen)-\(name).png"))
            }
        }
        XCUIDevice.shared.orientation = .portrait
    }
}
