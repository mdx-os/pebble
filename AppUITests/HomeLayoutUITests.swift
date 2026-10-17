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
    /// in both orientations. On iPhone the chat is alone and the memory
    /// opens over it.
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

    /// Command N starts a new chat; Command 2 and Command 1 move between places.
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
            app.typeKey("2", modifierFlags: .command)
            _ = note.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(note.exists)
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(composer(in: app).waitForExistence(timeout: 5))

        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Plan my morning"].waitForExistence(timeout: 5))
        XCTAssertFalse(earlier.exists)

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
                       ?? "home homeMemory shortcuts hello ideas firstChat confirm")
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
