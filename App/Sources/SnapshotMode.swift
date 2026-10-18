#if os(macOS)
import AppKit
import PebbleCore
import PebbleModel
import PebbleUI
import SwiftUI

/// Headless screenshots for `make screenshots` on macOS.
///
/// Launch with `-snapshotPath /path/to/file.png` and the app renders its first
/// screen at a standard window size, writes the PNG, and quits without
/// opening a window. iPhone and iPad screenshots come from the simulator.
///
/// `-snapshotSheet YES` draws the screen in a real window instead, so a sheet
/// it presents, such as the memory with its Done button, is presented as the
/// app would, and the sheet is what is written. `ImageRenderer` draws neither
/// sheets nor toolbars. The window sits off screen and is gone once the
/// picture is taken. `-snapshotDark YES` draws it in dark mode.
@MainActor
enum SnapshotMode {
    static let size = CGSize(width: 1280, height: 800)

    static func runIfRequested(brand: Brand) {
        guard let path = UserDefaults.standard.string(forKey: "snapshotPath") else { return }
        #if DEBUG
        let scene = UserDefaults.standard.string(forKey: ShowcaseScene.launchKey).flatMap(ShowcaseScene.init(rawValue:)) ?? .hello
        let screen = AnyView(scene.view(brand: brand))
        if UserDefaults.standard.bool(forKey: "snapshotSheet") {
            writeSheet(of: screen, to: path, dark: UserDefaults.standard.bool(forKey: "snapshotDark"))
        }
        #else
        let screen = AnyView(OnboardingView(brand: brand, names: InMemoryAgentNameStore(), store: InMemoryOnboardingStore()) { _ in })
        #endif
        let view = screen
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else {
            fail("render failed")
        }
        write(NSBitmapImageRep(cgImage: image), to: path)
    }

    /// Shows `screen` in a window, waits for the sheet it presents, and
    /// writes the sheet as drawn.
    private static func writeSheet(of screen: AnyView, to path: String, dark: Bool) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: screen.frame(width: size.width, height: size.height))
        window.orderFront(nil)
        // Long enough for the sheet to be presented and to finish moving in.
        let deadline = Date().addingTimeInterval(8)
        var settledAt: Date?
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            if window.attachedSheet != nil {
                settledAt = settledAt ?? Date()
                if Date().timeIntervalSince(settledAt!) > 1.5 { break }
            }
        }
        guard let sheet = window.attachedSheet, let frame = sheet.contentView?.superview ?? sheet.contentView else {
            fail("no sheet was presented")
        }
        frame.layoutSubtreeIfNeeded()
        guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { fail("sheet capture failed") }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        write(rep, to: path)
    }

    private static func write(_ rep: NSBitmapImageRep, to path: String) -> Never {
        guard let data = rep.representation(using: .png, properties: [:]) else {
            fail("PNG encoding failed")
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            fail(error.localizedDescription)
        }
        exit(0)
    }

    private static func fail(_ reason: String) -> Never {
        fputs("snapshot: \(reason)\n", stderr)
        exit(1)
    }
}
#endif
