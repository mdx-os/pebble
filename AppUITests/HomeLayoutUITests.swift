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

    private func launch(_ screen: String, textSize: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-showcaseScreen", screen]
        if let textSize { app.launchArguments += ["-UIPreferredContentSizeCategoryName", textSize] }
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

    /// At the largest text sizes the first run scrolls. Scrolled down to the
    /// button, the next page still opens at its top, heading in view.
    func testEachFirstRunPageOpensAtItsTop() throws {
        let app = launch("hello", textSize: "UICTContentSizeCategoryAccessibilityXXXL")
        let begin = app.buttons["Let's begin"]
        XCTAssertTrue(begin.waitForExistence(timeout: 10))
        for _ in 0..<8 { app.swipeUp() }
        XCTAssertTrue(begin.isHittable)
        let screen = app.windows.firstMatch.frame
        let hello = app.staticTexts["Hi there. I'm glad you're here."]
        if screen.contains(hello.frame) {
            throw XCTSkip("the whole page fits on this screen, so nothing scrolls")
        }
        begin.tap()
        let heading = app.staticTexts["What would you like to call me?"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        // The page's top is its step dots, above the character and the
        // heading. Past the page's slide in, they sit wholly on the screen,
        // so the heading below them does too, clear of the status bar.
        let steps = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Step 2 of")).firstMatch
        XCTAssertTrue(steps.waitForExistence(timeout: 5))
        let deadline = Date().addingTimeInterval(5)
        while !screen.contains(steps.frame), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(screen.contains(steps.frame), "the name page opens at its top: steps at \(steps.frame)")
        XCTAssertLessThan(steps.frame.maxY, heading.frame.minY)
        XCTAssertTrue(screen.contains(heading.frame), "the heading in view: \(heading.frame) on \(screen)")
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
    /// summary opens to read, and is an example here, saying so first. With
    /// no tasks to count, as in the app, the morning that never ran leaves
    /// no card claiming a summary was missed.
    func testTheMorningSummaryShowsInToday() throws {
        let app = launch("todaySummary")
        let summary = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Example. Ready for you. Your morning summary")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Needs you"].exists, "the question it counted still waits")
        let missed = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "I couldn't make")).firstMatch
        XCTAssertFalse(missed.exists)
        summary.tap()
        let detail = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Anything still waiting")).firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["sampleLabel"].exists)
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
    }

    /// Background work is off until the person turns it on, and then the
    /// screen says when the next summary is due. The whole row is the
    /// target, at the usual text size and the largest, so the switch turns
    /// on through its element; a tap right on the knob at its trailing
    /// edge turns it over exactly once too. What it promises is its own
    /// element, so VoiceOver reads it with hints off, and with no tasks to
    /// count, as in the app today, it doesn't promise what finished.
    func testBackgroundWorkIsOffUntilTurnedOn() throws {
        for textSize in [nil, "UICTContentSizeCategoryAccessibilityXXXL"] {
            let app = launch("memory", textSize: textSize)
            let toggle = app.switches["backgroundSwitch"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 10))
            for _ in 0..<8 where !toggle.isHittable { app.swipeUp() }
            XCTAssertTrue(toggle.isHittable)
            XCTAssertGreaterThanOrEqual(toggle.frame.height, 44, "a comfortable target at \(textSize ?? "default")")
            // VoiceOver hears one switch, by its title, and whether it is on.
            XCTAssertEqual(toggle.label, "Work while you're away")
            XCTAssertEqual(toggle.value as? String, "0")
            XCTAssertEqual(app.switches.matching(NSPredicate(format: "label == %@", "Work while you're away")).count, 1,
                           "the switch inside the row only shows the state")
            XCTAssertFalse(app.staticTexts["backgroundNext"].exists)
            let detail = app.staticTexts["backgroundDetail"]
            XCTAssertTrue(detail.exists)
            XCTAssertTrue(detail.label.contains("without asking you first"))
            XCTAssertFalse(detail.label.contains("finished"), "no tasks to count, so no promise about them")
            toggle.tap()
            XCTAssertTrue(app.staticTexts["backgroundNext"].waitForExistence(timeout: 5))
            XCTAssertEqual(toggle.value as? String, "1", "one tap, turned on once")
            XCTAssertEqual(toggle.label, "Work while you're away", "the same title while on")
            toggle.tap()
            XCTAssertTrue(app.staticTexts["backgroundNext"].waitForNonExistence(timeout: 5))
            XCTAssertEqual(toggle.value as? String, "0")
            // Right on the knob, where a switch and a row gesture could both fire.
            let knob = toggle.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
                .withOffset(CGVector(dx: -20, dy: 0))
            knob.tap()
            XCTAssertTrue(app.staticTexts["backgroundNext"].waitForExistence(timeout: 5))
            XCTAssertEqual(toggle.value as? String, "1", "one tap on the knob, turned on once")
            knob.tap()
            XCTAssertTrue(app.staticTexts["backgroundNext"].waitForNonExistence(timeout: 5))
            XCTAssertEqual(toggle.value as? String, "0", "and off once")
            app.terminate()
        }
    }

    /// An earlier launch left background work on, the way the version
    /// before kept it: the switch in UserDefaults and the morning summary
    /// queued in the runner's file. The app starts its runner as it always
    /// does, before launch ends, reads the switch as on and moves it beside
    /// the file, and the memory screen says when it looks next. The seed
    /// points the runner at a scratch folder, so nothing of the person's is
    /// touched, and it is the app's own home screen, not the showcase.
    ///
    /// The earlier version's setting comes from a launch argument, which
    /// lasts only for that launch. So the app opens again on the same
    /// folder without it, and is still on: the switch really moved beside
    /// the file, rather than being read from that argument each time.
    func testALaunchWithBackgroundWorkAlreadyOnKeepsItOn() throws {
        // A launch without the seed removes its scratch folder, so the
        // test leaves nothing behind in the app's temporary folder.
        addTeardownBlock {
            let clean = XCUIApplication()
            clean.launchArguments = ["-pebble.onboarding.finished", "YES"]
            clean.launch()
            clean.terminate()
        }
        let app = XCUIApplication()
        app.launchArguments = ["-backgroundSeed", "on", "-backgroundWork.on", "YES",
                               "-pebble.onboarding.finished", "YES", "-pebble.agent.displayName", "Pip"]
        app.launch()
        expectOnInMemoryScreen(app, "still on after the launch")
        app.terminate()

        // The same folder, without the earlier version's setting.
        app.launchArguments = ["-backgroundSeed", "again",
                               "-pebble.onboarding.finished", "YES", "-pebble.agent.displayName", "Pip"]
        app.launch()
        expectOnInMemoryScreen(app, "on, read from the switch's own file")
        app.terminate()
    }

    private func expectOnInMemoryScreen(_ app: XCUIApplication, _ why: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let memory = app.buttons["What I remember"].firstMatch
        XCTAssertTrue(memory.waitForExistence(timeout: 10), "the app's home, past the first run", file: file, line: line)
        memory.tap()
        let toggle = app.switches["backgroundSwitch"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), file: file, line: line)
        for _ in 0..<8 where !toggle.isHittable { app.swipeUp() }
        XCTAssertEqual(toggle.value as? String, "1", why, file: file, line: line)
        let next = app.staticTexts["backgroundNext"]
        XCTAssertTrue(next.waitForExistence(timeout: 5), why, file: file, line: line)
        XCTAssertTrue(next.label.hasPrefix("I'll look next"), next.label, file: file, line: line)
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
                app.launchArguments = ["-showcaseScreen", screen]
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
