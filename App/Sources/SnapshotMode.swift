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
@MainActor
enum SnapshotMode {
    static let size = CGSize(width: 1280, height: 800)

    static func runIfRequested(brand: Brand) {
        guard let path = UserDefaults.standard.string(forKey: "snapshotPath") else { return }
        let view = ChatView(brand: brand, model: LocalStubModel(), names: InMemoryAgentNameStore())
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else {
            fputs("snapshot: render failed\n", stderr)
            exit(1)
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            fputs("snapshot: PNG encoding failed\n", stderr)
            exit(1)
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            fputs("snapshot: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        exit(0)
    }
}
#endif
